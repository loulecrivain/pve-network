package PVE::Network::SDN::Zones::SimplePlugin;

use strict;
use warnings;
use PVE::Network::SDN::Zones::Plugin;
use PVE::Exception qw(raise raise_param_exc);
use PVE::Cluster;
use PVE::Tools;

use base('PVE::Network::SDN::Zones::Plugin');

sub type {
    return 'simple';
}

sub options {
    return {
	nodes => { optional => 1},
	mtu => { optional => 1 }
    };
}

# Plugin implementation
sub generate_sdn_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $controller, $subnet_cfg, $interfaces_config, $config) = @_;

    return $config if$config->{$vnetid}; # nothing to do

    my $ipv4 = $vnet->{ipv4};
    my $ipv6 = $vnet->{ipv6};
    my $mac = $vnet->{mac};
    my $alias = $vnet->{alias};
    my $mtu = $plugin_config->{mtu} if $plugin_config->{mtu};

    # vnet bridge
    my @iface_config = ();

    my @subnets = PVE::Tools::split_list($vnet->{subnets}) if $vnet->{subnets};
    foreach my $subnet (@subnets) {
	next if !defined($subnet_cfg->{ids}->{$subnet});
	push @iface_config, "address $subnet_cfg->{ids}->{$subnet}->{gateway}" if $subnet_cfg->{ids}->{$subnet}->{gateway};
    }

    push @iface_config, "hwaddress $mac" if $mac;
    push @iface_config, "bridge_ports none";
    push @iface_config, "bridge_stp off";
    push @iface_config, "bridge_fd 0";
    if ($vnet->{vlanaware}) {
        push @iface_config, "bridge-vlan-aware yes";
        push @iface_config, "bridge-vids 2-4094";
    }
    push @iface_config, "mtu $mtu" if $mtu;
    push @iface_config, "alias $alias" if $alias;

    push @{$config->{$vnetid}}, @iface_config;

    return $config;
}

sub status {
    my ($class, $plugin_config, $zone, $vnetid, $vnet, $status) = @_;

    # ifaces to check
    my $ifaces = [ $vnetid ];
    my $err_msg = [];
    foreach my $iface (@{$ifaces}) {
	if (!$status->{$iface}->{status}) {
	    push @$err_msg, "missing $iface";
	} elsif ($status->{$iface}->{status} ne 'pass') {
	    push @$err_msg, "error iface $iface";
	}
    }
    return $err_msg;
}


sub vnet_update_hook {
    my ($class, $vnet) = @_;

    raise_param_exc({ tag => "vlan tag is not allowed on simple bridge"}) if defined($vnet->{tag});

    if (!defined($vnet->{mac})) {
        my $dc = PVE::Cluster::cfs_read_file('datacenter.cfg');
        $vnet->{mac} = PVE::Tools::random_ether_addr($dc->{mac_prefix});
    }
}

1;

