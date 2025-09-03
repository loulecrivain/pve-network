package PVE::Network::SDN::Ipams;

use strict;
use warnings;

use JSON;
use Net::IP;

use PVE::Tools qw(extract_param dir_glob_regex run_command);
use PVE::Cluster qw(cfs_register_file cfs_read_file cfs_write_file cfs_lock_file);
use PVE::Network;

use PVE::Network::SDN::Ipams::PVEPlugin;
use PVE::Network::SDN::Ipams::NetboxPlugin;
use PVE::Network::SDN::Ipams::NautobotPlugin;
use PVE::Network::SDN::Ipams::PhpIpamPlugin;
use PVE::Network::SDN::Ipams::Plugin;


PVE::Network::SDN::Ipams::PVEPlugin->register();
PVE::Network::SDN::Ipams::NetboxPlugin->register();
PVE::Network::SDN::Ipams::NautobotPlugin->register();
PVE::Network::SDN::Ipams::PhpIpamPlugin->register();
PVE::Network::SDN::Ipams::Plugin->init();

my $macdb_filename = "sdn/mac-cache.json";
cfs_register_file($macdb_filename, \&json_reader, \&json_writer);

sub json_reader {
    my ($filename, $data) = @_;

    return defined($data) && length($data) > 0 ? decode_json($data) : {};
}

sub json_writer {
    my ($filename, $data) = @_;

    return encode_json($data);
}

sub read_macdb {
    my () = @_;

    return cfs_read_file($macdb_filename);
}

sub write_macdb {
    my ($data) = @_;

    cfs_write_file($macdb_filename, $data);
}

sub add_cache_mac_ip {
    my ($mac, $ip) = @_;

    cfs_lock_file(
        $macdb_filename,
        undef,
        sub {
            my $db = read_macdb();
            if (Net::IP::ip_is_ipv4($ip)) {
                $db->{macs}->{$mac}->{ip4} = $ip;
            } else {
                $db->{macs}->{$mac}->{ip6} = $ip;
            }
            write_macdb($db);
        },
    );
    warn "$@" if $@;
}

sub del_cache_mac_ip {
    my ($mac, $ip) = @_;

    cfs_lock_file(
        $macdb_filename,
        undef,
        sub {
            my $db = read_macdb();
            if (Net::IP::ip_is_ipv4($ip)) {
                delete $db->{macs}->{$mac}->{ip4};
            } else {
                delete $db->{macs}->{$mac}->{ip6};
            }
            delete $db->{macs}->{$mac}
                if !defined($db->{macs}->{$mac}->{ip4}) && !defined($db->{macs}->{$mac}->{ip6});
            write_macdb($db);
        },
    );
    warn "$@" if $@;
}

sub sdn_ipams_config {
    my ($cfg, $id, $noerr) = @_;

    die "no sdn ipam ID specified\n" if !$id;

    my $scfg = $cfg->{ids}->{$id};
    die "sdn '$id' does not exist\n" if (!$noerr && !$scfg);

    return $scfg;
}

sub config {
    my $config = cfs_read_file("sdn/ipams.cfg");
    #add default internal pve
    $config->{ids}->{pve}->{type} = 'pve';
    return $config;
}

sub get_plugin_config {
    my ($zone) = @_;
    my $ipamid = $zone->{ipam};
    my $ipam_cfg = PVE::Network::SDN::Ipams::config();
    return $ipam_cfg->{ids}->{$ipamid};
}

sub write_config {
    my ($cfg) = @_;

    cfs_write_file("sdn/ipams.cfg", $cfg);
}

sub sdn_ipams_ids {
    my ($cfg) = @_;

    return keys %{ $cfg->{ids} };
}

sub complete_sdn_vnet {
    my ($cmdname, $pname, $cvalue) = @_;

    my $cfg = PVE::Network::SDN::Ipams::config();

    return $cmdname eq 'add' ? [] : [PVE::Network::SDN::Vnets::sdn_ipams_ids($cfg)];
}

sub get_ips_from_mac {
    my ($mac, $zoneid, $zone) = @_;

    my $macdb = read_macdb();
    return ($macdb->{macs}->{$mac}->{ip4}, $macdb->{macs}->{$mac}->{ip6}) if $macdb->{macs}->{$mac};

    my $plugin_config = get_plugin_config($zone);
    my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($plugin_config->{type});
    ($macdb->{macs}->{$mac}->{ip4}, $macdb->{macs}->{$mac}->{ip6}) =
        $plugin->get_ips_from_mac($plugin_config, $mac, $zoneid);

    write_macdb($macdb);

    return ($macdb->{macs}->{$mac}->{ip4}, $macdb->{macs}->{$mac}->{ip6});
}

1;

