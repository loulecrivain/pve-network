package PVE::Network::SDN::Subnets;

use strict;
use warnings;

use Net::Subnet qw(subnet_matcher);
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use Net::IP;

use PVE::Network::SDN::Ipams;
use PVE::Network::SDN::Dns;
use PVE::Network::SDN::SubnetPlugin;
PVE::Network::SDN::SubnetPlugin->register();
PVE::Network::SDN::SubnetPlugin->init();

sub sdn_subnets_config {
    my ($cfg, $id, $noerr) = @_;

    die "no sdn subnet ID specified\n" if !$id;

    my $scfg = $cfg->{ids}->{$id};
    die "sdn subnet '$id' does not exist\n" if (!$noerr && !$scfg);

    return $scfg;
}

sub config {
    my $config = cfs_read_file("sdn/subnets.cfg");
}

sub write_config {
    my ($cfg) = @_;

    cfs_write_file("sdn/subnets.cfg", $cfg);
}

sub sdn_subnets_ids {
    my ($cfg) = @_;

    return keys %{$cfg->{ids}};
}

sub complete_sdn_subnet {
    my ($cmdname, $pname, $cvalue) = @_;

    my $cfg = PVE::Network::SDN::Subnets::config();

    return  $cmdname eq 'add' ? [] : [ PVE::Network::SDN::Subnets::sdn_subnets_ids($cfg) ];
}

sub get_subnet {
    my ($subnetid) = @_;

    my $cfg = PVE::Network::SDN::Subnets::config();
    my $subnet = PVE::Network::SDN::Subnets::sdn_subnets_config($cfg, $subnetid, 1);
    return $subnet;
}

sub find_ip_subnet {
    my ($ip, $subnetslist) = @_;

    my $subnets_cfg = PVE::Network::SDN::Subnets::config();
    my @subnets = PVE::Tools::split_list($subnetslist) if $subnetslist;

    my $subnet = undef;
    my $subnetid = undef;

    foreach my $s (@subnets) {
        my $subnet_matcher = subnet_matcher($s);
        next if !$subnet_matcher->($ip);
        $subnetid = $s =~ s/\//-/r;
        $subnet = $subnets_cfg->{ids}->{$subnetid};
        last;
    }
    die  "can't find any subnet for ip $ip" if !$subnet;

    return ($subnetid, $subnet);
}

my $verify_dns_zone = sub {
    my ($zone, $dns) = @_;

    return if !$zone || !$dns;

    my $dns_cfg = PVE::Network::SDN::Dns::config();
    my $plugin_config = $dns_cfg->{ids}->{$dns};
    my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($plugin_config->{type});
    $plugin->verify_zone($plugin_config, $zone);
};

my $add_dns_record = sub {
    my ($zone, $dns, $hostname, $dnszoneprefix, $ip) = @_;
    return if !$zone || !$dns || !$hostname || !$ip;

    $hostname .= ".$dnszoneprefix" if $dnszoneprefix;

    my $dns_cfg = PVE::Network::SDN::Dns::config();
    my $plugin_config = $dns_cfg->{ids}->{$dns};
    my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($plugin_config->{type});
    $plugin->add_a_record($plugin_config, $zone, $hostname, $ip);

};

my $add_dns_ptr_record = sub {
    my ($reversezone, $zone, $dns, $hostname, $dnszoneprefix, $ip) = @_;

    return if !$zone || !$reversezone || !$dns || !$hostname || !$ip;

    $hostname .= ".$dnszoneprefix" if $dnszoneprefix;
    $hostname .= ".$zone";
    my $dns_cfg = PVE::Network::SDN::Dns::config();
    my $plugin_config = $dns_cfg->{ids}->{$dns};
    my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($plugin_config->{type});
    $plugin->add_ptr_record($plugin_config, $reversezone, $hostname, $ip);
};

my $del_dns_record = sub {
    my ($zone, $dns, $hostname, $dnszoneprefix, $ip) = @_;

    return if !$zone || !$dns || !$hostname || !$ip;

    $hostname .= ".$dnszoneprefix" if $dnszoneprefix;

    my $dns_cfg = PVE::Network::SDN::Dns::config();
    my $plugin_config = $dns_cfg->{ids}->{$dns};
    my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($plugin_config->{type});
    $plugin->del_a_record($plugin_config, $zone, $hostname, $ip);
};

my $del_dns_ptr_record = sub {
    my ($reversezone, $dns, $ip) = @_;

    return if !$reversezone || !$dns || !$ip;

    my $dns_cfg = PVE::Network::SDN::Dns::config();
    my $plugin_config = $dns_cfg->{ids}->{$dns};
    my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($plugin_config->{type});
    $plugin->del_ptr_record($plugin_config, $reversezone, $ip);
};

sub next_free_ip {
    my ($subnetid, $subnet, $hostname) = @_;

    my $cidr = undef;
    my $ip = undef;

    my $ipamid = $subnet->{ipam};
    my $dns = $subnet->{dns};
    my $dnszone = $subnet->{dnszone};
    my $reversedns = $subnet->{reversedns};
    my $reversednszone = $subnet->{reversednszone};
    my $dnszoneprefix = $subnet->{dnszoneprefix};

    #verify dns zones before ipam
    &$verify_dns_zone($dnszone, $dns);
    &$verify_dns_zone($reversednszone, $reversedns);

    if($ipamid) {
	my $ipam_cfg = PVE::Network::SDN::Ipams::config();
	my $plugin_config = $ipam_cfg->{ids}->{$ipamid};
	my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($plugin_config->{type});
	$cidr = $plugin->add_next_freeip($plugin_config, $subnetid, $subnet);
	($ip, undef) = split(/\//, $cidr);
    }

    eval {
	#add dns
	&$add_dns_record($dnszone, $dns, $hostname, $dnszoneprefix, $ip);
	#add reverse dns
	&$add_dns_ptr_record($reversednszone, $dnszone, $reversedns, $hostname, $dnszoneprefix, $ip);
    };
    if ($@) {
	#rollback
	my $err = $@;
	eval {
	    PVE::Network::SDN::Subnets::del_ip($subnetid, $subnet, $ip, $hostname)
	};
	die $err;
    }
    return $cidr;
}

sub add_ip {
    my ($subnetid, $subnet, $ip, $hostname) = @_;

    my $ipamid = $subnet->{ipam};
    my $dns = $subnet->{dns};
    my $dnszone = $subnet->{dnszone};
    my $reversedns = $subnet->{reversedns};
    my $reversednszone = $subnet->{reversednszone};
    my $dnszoneprefix = $subnet->{dnszoneprefix};

    #verify dns zones before ipam
    &$verify_dns_zone($dnszone, $dns);
    &$verify_dns_zone($reversednszone, $reversedns);

    if ($ipamid) {
	my $ipam_cfg = PVE::Network::SDN::Ipams::config();
	my $plugin_config = $ipam_cfg->{ids}->{$ipamid};
	my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($plugin_config->{type});
	$plugin->add_ip($plugin_config, $subnetid, $ip);
    }

    eval {
	#add dns
	&$add_dns_record($dnszone, $dns, $hostname, $dnszoneprefix, $ip);
	#add reverse dns
	&$add_dns_ptr_record($reversednszone, $dnszone, $reversedns, $hostname, $dnszoneprefix, $ip);
    };
    if ($@) {
	#rollback
	my $err = $@;
	eval {
	    PVE::Network::SDN::Subnets::del_ip($subnetid, $subnet, $ip, $hostname)
	};
	die $err;
    }
}

sub del_ip {
    my ($subnetid, $subnet, $ip, $hostname) = @_;

    my $ipamid = $subnet->{ipam};
    my $dns = $subnet->{dns};
    my $dnszone = $subnet->{dnszone};
    my $reversedns = $subnet->{reversedns};
    my $reversednszone = $subnet->{reversednszone};
    my $dnszoneprefix = $subnet->{dnszoneprefix};

    &$verify_dns_zone($dnszone, $dns);
    &$verify_dns_zone($reversednszone, $reversedns);

    if ($ipamid) {
	my $ipam_cfg = PVE::Network::SDN::Ipams::config();
	my $plugin_config = $ipam_cfg->{ids}->{$ipamid};
	my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($plugin_config->{type});
	$plugin->del_ip($plugin_config, $subnetid, $ip);
    }

    eval {
	&$del_dns_record($dnszone, $dns, $hostname, $dnszoneprefix, $ip);
	&$del_dns_ptr_record($reversednszone, $reversedns, $ip);
    };
    if ($@) {
	warn $@;
    }
}

1;