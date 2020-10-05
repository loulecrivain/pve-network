package PVE::Network::SDN::Zones;

use strict;
use warnings;

use Data::Dumper;
use JSON;

use PVE::Tools qw(extract_param dir_glob_regex run_command);
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use PVE::Network;

use PVE::Network::SDN::Vnets;
use PVE::Network::SDN::Subnets;
use PVE::Network::SDN::Zones::VlanPlugin;
use PVE::Network::SDN::Zones::QinQPlugin;
use PVE::Network::SDN::Zones::VxlanPlugin;
use PVE::Network::SDN::Zones::EvpnPlugin;
use PVE::Network::SDN::Zones::FaucetPlugin;
use PVE::Network::SDN::Zones::SimplePlugin;
use PVE::Network::SDN::Zones::Plugin;

PVE::Network::SDN::Zones::VlanPlugin->register();
PVE::Network::SDN::Zones::QinQPlugin->register();
PVE::Network::SDN::Zones::VxlanPlugin->register();
PVE::Network::SDN::Zones::EvpnPlugin->register();
PVE::Network::SDN::Zones::FaucetPlugin->register();
PVE::Network::SDN::Zones::SimplePlugin->register();
PVE::Network::SDN::Zones::Plugin->init();

my $local_network_sdn_file = "/etc/network/interfaces.d/sdn";

sub sdn_zones_config {
    my ($cfg, $id, $noerr) = @_;

    die "no sdn zone ID specified\n" if !$id;

    my $scfg = $cfg->{ids}->{$id};
    die "sdn '$id' does not exist\n" if (!$noerr && !$scfg);

    return $scfg;
}

sub config {
    my $config = cfs_read_file("sdn/zones.cfg");
    return $config;
}

sub get_plugin_config {
    my ($vnet) = @_;
    my $zoneid = $vnet->{zone};
    my $zone_cfg = PVE::Network::SDN::Zones::config();
    return $zone_cfg->{ids}->{$zoneid};
}

sub write_config {
    my ($cfg) = @_;

    cfs_write_file("sdn/zones.cfg", $cfg);
}

sub sdn_zones_ids {
    my ($cfg) = @_;

    return keys %{$cfg->{ids}};
}

sub complete_sdn_zone {
    my ($cmdname, $pname, $cvalue) = @_;

    my $cfg = PVE::Network::SDN::config();

    return  $cmdname eq 'add' ? [] : [ PVE::Network::SDN::sdn_zones_ids($cfg) ];
}


sub generate_etc_network_config {

    my $version = PVE::Cluster::cfs_read_file('sdn/.version');
    my $vnet_cfg = PVE::Cluster::cfs_read_file('sdn/vnets.cfg');
    my $zone_cfg = PVE::Cluster::cfs_read_file('sdn/zones.cfg');
    my $subnet_cfg = PVE::Network::SDN::Subnets::config();
    my $controller_cfg = PVE::Cluster::cfs_read_file('sdn/controllers.cfg');
    return if !$vnet_cfg && !$zone_cfg;

    my $interfaces_config = PVE::INotify::read_file('interfaces');

    #generate configuration
    my $config = {};
    my $nodename = PVE::INotify::nodename();

    for my $id (sort keys %{$vnet_cfg->{ids}}) {
	my $vnet = $vnet_cfg->{ids}->{$id};
	my $zone = $vnet->{zone};

	if (!$zone) {
	    warn "can't generate vnet '$id': no zone assigned!\n";
	    next;
	}

	my $plugin_config = $zone_cfg->{ids}->{$zone};

	if (!defined($plugin_config)) {
	    warn "can't generate vnet '$id': zone $zone don't exist\n";
	    next;
	}

	next if defined($plugin_config->{nodes}) && !$plugin_config->{nodes}->{$nodename};

	my $controller;
	if (my $controllerid = $plugin_config->{controller}) {
	    $controller = $controller_cfg->{ids}->{$controllerid};
	}

	my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
	eval {
	    $plugin->generate_sdn_config($plugin_config, $zone, $id, $vnet, $controller, $subnet_cfg, $interfaces_config, $config);
	};
	if (my $err = $@) {
	    warn "zone $zone : vnet $id : $err\n";
	    next;
	}
    }

    my $raw_network_config = "\#version:$version\n";
    foreach my $iface (sort keys %$config) {
	$raw_network_config .= "\n";
	$raw_network_config .= "auto $iface\n";
	$raw_network_config .= "iface $iface\n";
	foreach my $option (@{$config->{$iface}}) {
	    $raw_network_config .= "\t$option\n";
	}
    }

    return $raw_network_config;
}

sub write_etc_network_config {
    my ($rawconfig) = @_;

    return if !$rawconfig;

    my $writefh = IO::File->new($local_network_sdn_file,">");
    print $writefh $rawconfig;
    $writefh->close();
}

sub read_etc_network_config_version {
    my $versionstr = PVE::Tools::file_read_firstline($local_network_sdn_file);

    return if !defined($versionstr);

    if ($versionstr =~ m/^\#version:(\d+)$/) {
	return $1;
    }
}

sub ifquery_check {

    my $cmd = ['ifquery', '-a', '-c', '-o','json'];

    my $result = '';
    my $reader = sub { $result .= shift };

    eval {
	run_command($cmd, outfunc => $reader);
    };

    my $resultjson = decode_json($result);
    my $interfaces = {};

    foreach my $interface (@$resultjson) {
	my $name = $interface->{name};
	$interfaces->{$name} = {
	    status => $interface->{status},
	    config => $interface->{config},
	    config_status => $interface->{config_status},
	};
    }

    return $interfaces;
}

my $warned_about_reload;

sub status {

    my $err_config = undef;

    my $local_version = PVE::Network::SDN::Zones::read_etc_network_config_version();
    my $sdn_version = PVE::Cluster::cfs_read_file('sdn/.version');

    return if !$sdn_version;

    if (!$local_version) {
	$err_config = "local sdn network configuration is not yet generated, please reload";
	if (!$warned_about_reload) {
	    $warned_about_reload = 1;
	    warn "$err_config\n";
	}
    } elsif ($local_version < $sdn_version) {
	$err_config = "local sdn network configuration is too old, please reload";
	if (!$warned_about_reload) {
	    $warned_about_reload = 1;
	    warn "$err_config\n";
	}
    } else {
	$warned_about_reload = 0;
    }

    my $status = ifquery_check();

    my $vnet_cfg = PVE::Cluster::cfs_read_file('sdn/vnets.cfg');
    my $zone_cfg = PVE::Cluster::cfs_read_file('sdn/zones.cfg');
    my $nodename = PVE::INotify::nodename();

    my $vnet_status = {};
    my $zone_status = {};

    for my $id (sort keys %{$zone_cfg->{ids}}) {
	$zone_status->{$id}->{status} = $err_config ? 'pending' : 'available';
    }

    foreach my $id (sort keys %{$vnet_cfg->{ids}}) {
	my $vnet = $vnet_cfg->{ids}->{$id};
	my $zone = $vnet->{zone};
	next if !$zone;

	my $plugin_config = $zone_cfg->{ids}->{$zone};
	next if defined($plugin_config->{nodes}) && !$plugin_config->{nodes}->{$nodename};

	$vnet_status->{$id}->{zone} = $zone;
	$vnet_status->{$id}->{status} = 'available';

	if ($err_config) {
	    $vnet_status->{$id}->{status} = 'pending';
	    $vnet_status->{$id}->{statusmsg} = $err_config;
	    next;
	}

	my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
	my $err_msg = $plugin->status($plugin_config, $zone, $id, $vnet, $status);
	if (@{$err_msg} > 0) {
	    $vnet_status->{$id}->{status} = 'error';
	    $vnet_status->{$id}->{statusmsg} = join(',', @{$err_msg});
	    $zone_status->{$id}->{status} = 'error';
	}
    }

    return ($zone_status, $vnet_status);
}

sub tap_create {
    my ($iface, $bridge) = @_;

    my $vnet = PVE::Network::SDN::Vnets::get_vnet($bridge);
    if (!$vnet) { # fallback for classic bridge
	PVE::Network::tap_create($iface, $bridge);
	return;
    }

    my $plugin_config = get_plugin_config($vnet);
    my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
    $plugin->tap_create($plugin_config, $vnet, $iface, $bridge);
}

sub veth_create {
    my ($veth, $vethpeer, $bridge, $hwaddr) = @_;

    my $vnet = PVE::Network::SDN::Vnets::get_vnet($bridge);
    if (!$vnet) { # fallback for classic bridge
	PVE::Network::veth_create($veth, $vethpeer, $bridge, $hwaddr);
	return;
    }

    my $plugin_config = get_plugin_config($vnet);
    my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
    $plugin->veth_create($plugin_config, $vnet, $veth, $vethpeer, $bridge, $hwaddr);
}

sub tap_plug {
    my ($iface, $bridge, $tag, $firewall, $trunks, $rate) = @_;

    my $vnet = PVE::Network::SDN::Vnets::get_vnet($bridge);
    if (!$vnet) { # fallback for classic bridge
	PVE::Network::tap_plug($iface, $bridge, $tag, $firewall, $trunks, $rate);
	return;
    }

    my $plugin_config = get_plugin_config($vnet);
    my $nodename = PVE::INotify::nodename();

    die "vnet $bridge is not allowed on this node\n"
	if $plugin_config->{nodes} && !defined($plugin_config->{nodes}->{$nodename});

    my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
    $plugin->tap_plug($plugin_config, $vnet, $tag, $iface, $bridge, $firewall, $trunks, $rate);
}

1;

