package PVE::Network::SDN::Ipams::NautobotPlugin;

use strict;
use warnings;
use PVE::INotify;
use PVE::Cluster;
use PVE::Tools;
use NetAddr::IP;
use Net::Subnet qw(subnet_matcher);

use base('PVE::Network::SDN::Ipams::Plugin');

sub type {
    return 'nautobot';
}

sub properties {
    return {
        namespace => {
            type => 'string',
        },
    };
}

sub options {
    return {
        url => { optional => 0 },
        token => { optional => 0 },
        namespace => { optional => 0 },
        fingerprint => { optional => 1 },
    };
}

sub default_ip_status {
    return 'Active';
}

sub nautobot_api_request {
    my ($config, $method, $path, $params) = @_;

    return PVE::Network::SDN::api_request(
        $method,
        "$config->{url}${path}",
        [
            'Content-Type' => 'application/json; charset=UTF-8',
            'Authorization' => "token $config->{token}",
            'Accept' => "application/json",
        ],
        $params,
        $config->{fingerprint},
    );
}

sub add_subnet {
    my ($class, $config, undef, $subnet, $noerr) = @_;

    my $cidr = $subnet->{cidr};
    my $namespace = $config->{namespace};

    my $internalid = get_prefix_id($config, $cidr, $noerr);
    if ($internalid) {
        return if $noerr;
        die "could not add the subnet $subnet because it already exists in nautobot\n";
    }

    my $params = {
        prefix => $cidr,
        namespace => $namespace,
        status => default_ip_status(),
    };

    eval { nautobot_api_request($config, "POST", "/ipam/prefixes/", $params); };
    if ($@) {
        return if $noerr;
        die "error adding the subnet $subnet to nautobot $@\n";
    }
}

sub update_subnet {
    my ($class, $plugin_config, $subnetid, $subnet, $old_subnet, $noerr) = @_;
    # dhcp ranges are not supported in nautobot so we don't have to update them
}

sub del_subnet {
    my ($class, $config, $subnetid, $subnet, $noerr) = @_;

    my $cidr = $subnet->{cidr};

    my $internalid = get_prefix_id($config, $cidr, $noerr);
    if (!$internalid) {
        warn("could not find delete the subnet $cidr because it does not exist in nautobot\n");
        return;
    }

    if (!subnet_is_deletable($config, $subnetid, $subnet, $internalid, $noerr)) {
        return if $noerr;
        die "could not delete the subnet $cidr, it still contains ip addresses!\n";
    }

    # delete associated gateway IP addresses
    $class->empty_subnet($config, $subnetid, $subnet, $internalid, $noerr);

    eval { nautobot_api_request($config, "DELETE", "/ipam/prefixes/$internalid/"); };
    if ($@) {
        return if $noerr;
        die "error deleting subnet from nautobot: $@\n";
    }
    return 1;
}

sub add_ip {
    my ($class, $config, undef, $subnet, $ip, $hostname, $mac, undef, $is_gateway, $noerr) = @_;

    my $mask = $subnet->{mask};
    my $namespace = $config->{namespace};

    my $description = undef;
    if ($is_gateway) {
        $description = 'gateway';
    } elsif ($mac) {
        $description = "mac:$mac";
    }

    my $params = {
        address => "$ip/$mask",
        type => "dhcp",
        description => $description,
        namespace => $namespace,
        status => default_ip_status(),
    };

    eval { nautobot_api_request($config, "POST", "/ipam/ip-addresses/", $params); };

    if ($@) {
        if ($is_gateway) {
            die "error add subnet ip to ipam: ip $ip already exist: $@"
                if !is_ip_gateway($config, $ip, $noerr);
        } elsif (!$noerr) {
            die "error add subnet ip to ipam: ip already exist: $@";
        }
    }
}

sub add_next_freeip {
    my ($class, $config, undef, $subnet, $hostname, $mac, undef, $noerr) = @_;

    my $cidr = $subnet->{cidr};
    my $namespace = $config->{namespace};

    my $internalid = get_prefix_id($config, $cidr, $noerr);
    if (!defined($internalid)) {
        return if $noerr;
        die "could not find prefix $cidr in nautobot\n";
    }

    my $description = undef;
    $description = "mac:$mac" if $mac;

    my $params = {
        type => "dhcp",
        description => $description,
        namespace => $namespace,
        status => default_ip_status(),
    };

    my $response = eval {
        return nautobot_api_request(
            $config, "POST", "/ipam/prefixes/$internalid/available-ips/", $params,
        );
    };
    if ($@ || !$response) {
        return if $noerr;
        die "could not allocate ip in subnet $cidr: $@\n";
    }

    my $ip = NetAddr::IP->new($response->{address});

    return $ip->addr;
}

sub find_ip_in_prefix {
    my ($config, $prefix_id, $limit, $start_range, $end_range) = @_;

    # Fetch available IPs from the temporary pool and find a matching IP
    my $result = eval {
        return nautobot_api_request(
            $config,
            "GET",
            "/ipam/prefixes/$prefix_id/available-ips/?limit=$limit",
        );
    };

    # search list for IPs in actual range
    if (!$@ && defined($result)) {
        foreach my $entry (@$result) {
            my $ip = NetAddr::IP->new($entry->{address});
            # comparison is only possible because they are in the same subnet
            if ($start_range <= $ip && $ip <= $end_range) {
                return $ip->addr;
            }
        }
    }
    return;
}

sub add_range_next_freeip {
    my ($class, $config, $subnet, $range, $data, $noerr) = @_;

    my $cidr = NetAddr::IP->new($subnet->{cidr});
    my $namespace = $config->{namespace};

    # Nautobot does not support IP ranges, only prefixes.
    # Therefore we divide the range into smaller pool prefixes,
    # each containing 256 addresses, and search them for available IPs
    my $prefix_size = $cidr->version == 4 ? 24 : 120;
    my $increment = 256;
    my $found_ip = undef;

    my $start_range = NetAddr::IP->new($range->{'start-address'}, $prefix_size);
    my $end_range = NetAddr::IP->new($range->{'end-address'}, $prefix_size);
    my $matcher = subnet_matcher($end_range->cidr);
    my $current_ip = $start_range;

    while (1) {
        my $current_cidr = $current_ip->addr . "/$prefix_size";

        my $params = {
            prefix => $current_cidr,
            namespace => $namespace,
            status => default_ip_status(),
            type => "pool",
        };

        my $prefix_id = get_prefix_id($config, $current_cidr, $noerr);
        if ($prefix_id) {
            # search the existing prefix for valid ip
            $found_ip =
                find_ip_in_prefix($config, $prefix_id, $increment, $start_range, $end_range);
        } else {
            # create temporary pool prefix
            my $temp_prefix =
                eval { return nautobot_api_request($config, "POST", "/ipam/prefixes/", $params); };

            my $temp_prefix_id = $temp_prefix->{id};

            # search temporarly created prefix
            $found_ip =
                find_ip_in_prefix($config, $temp_prefix_id, $increment, $start_range, $end_range);

            # Delete temporary prefix pool
            eval { nautobot_api_request($config, "DELETE", "/ipam/prefixes/$temp_prefix_id/"); };
        }

        last if $found_ip;

        # we searched the last pool prefix
        last if $matcher->($current_ip->addr);

        $current_ip = $current_ip->plus($increment);
    }

    if (!$found_ip) {
        return if $noerr;
        die "could not allocate ip in the range "
            . $start_range->addr . " - "
            . $end_range->addr
            . ": $@\n";
    }

    $class->add_ip(
        $config,
        undef,
        $subnet,
        $found_ip,
        $data->{hostname},
        $data->{mac},
        undef,
        0,
        $noerr,
    );

    return $found_ip;
}

sub update_ip {
    my ($class, $config, $subnetid, $subnet, $ip, $hostname, $mac, undef, $is_gateway, $noerr) = @_;

    my $mask = $subnet->{mask};
    my $namespace = $config->{namespace};

    my $description = undef;
    if ($is_gateway) {
        $description = 'gateway';
    } elsif ($mac) {
        $description = "mac:$mac";
    }

    my $params = {
        address => "$ip/$mask",
        type => "dhcp",
        description => $description,
        namespace => $namespace,
        status => default_ip_status(),
    };

    my $ip_id = get_ip_id($config, $ip, $noerr);
    if (!defined($ip_id)) {
        return if $noerr;
        die "could not find the ip $ip in nautobot\n";
    }

    eval { nautobot_api_request($config, "PATCH", "/ipam/ip-addresses/$ip_id/", $params); };
    if ($@) {
        return if $noerr;
        die "error updating ip $ip: $@";
    }
}

sub del_ip {
    my ($class, $config, undef, undef, $ip, $noerr) = @_;

    return if !$ip;

    my $ip_id = get_ip_id($config, $ip, $noerr);
    if (!defined($ip_id)) {
        warn("could not find the ip $ip in nautobot\n");
        return;
    }

    eval { nautobot_api_request($config, "DELETE", "/ipam/ip-addresses/$ip_id/"); };
    if ($@) {
        return if $noerr;
        die "error deleting ip $ip : $@\n";
    }

    return 1;
}

sub empty_subnet {
    my ($class, $config, $subnetid, $subnet, $subnetuuid, $noerr) = @_;

    my $namespace = $config->{namespace};

    my $response = eval {
        return nautobot_api_request(
            $config,
            "GET",
            "/ipam/ip-addresses/?namespace=$namespace&parent=$subnetuuid",
        );
    };
    if ($@) {
        return if $noerr;
        die "could not find the subnet $subnet in nautobot: $@\n";
    }

    for my $ip (@{ $response->{results} }) {
        del_ip($class, $config, undef, undef, $ip->{host}, $noerr);
    }

    return 1;
}

sub subnet_is_deletable {
    my ($config, $subnetid, $subnet, $subnetuuid, $noerr) = @_;

    my $namespace = $config->{namespace};

    my $response = eval {
        return nautobot_api_request(
            $config,
            "GET",
            "/ipam/ip-addresses/?namespace=$namespace&parent=$subnetuuid",
        );
    };
    if ($@) {
        return if $noerr;
        die "error querying prefix $subnet: $@\n";
    }
    my $n_ips = scalar $response->{results}->@*;

    # least costly check operation 1st
    return 1 if ($n_ips == 0);

    for my $ip (values $response->{results}->@*) {
        if (!is_ip_gateway($config, $ip->{host}, $noerr)) {
            # some remaining IP is not a gateway so we can't delete the subnet
            return 0;
        }
    }
    #all remaining IPs are gateways
    return 1;
}

sub verify_api {
    my ($class, $config) = @_;

    my $namespace = $config->{namespace};

    # check if the namespace and the status "Active" exist
    eval {
        get_namespace_id($config, $namespace) // die "namespace $namespace does not exist";
        get_status_id($config, default_ip_status())
            // die "the status " . default_ip_status() . " does not exist";
    };
    if ($@) {
        die "could not use nautobot api: $@\n";
    }
}

sub get_ips_from_mac {
    my ($class, $config, $mac, $zone) = @_;

    my $ip4 = undef;
    my $ip6 = undef;

    my $data = eval { nautobot_api_request($config, "GET", "/ipam/ip-addresses/?q=$mac"); };
    if ($@) {
        die "could not query ip address entry for mac $mac: $@";
    }

    for my $ip (@{ $data->{results} }) {
        if ($ip->{ip_version} == 4 && !$ip4) {
            ($ip4, undef) = split(/\//, $ip->{address});
        }

        if ($ip->{ip_version} == 6 && !$ip6) {
            ($ip6, undef) = split(/\//, $ip->{address});
        }
    }

    return ($ip4, $ip6);
}

sub on_update_hook {
    my ($class, $config) = @_;

    PVE::Network::SDN::Ipams::NautobotPlugin::verify_api($class, $config);
}

sub get_ip_id {
    my ($config, $ip, $noerr) = @_;

    my $result =
        eval { return nautobot_api_request($config, "GET", "/ipam/ip-addresses/?address=$ip"); };
    if ($@) {
        return if $noerr;
        die "error while querying for ip $ip id: $@\n";
    }

    my $data = @{ $result->{results} }[0];
    return $data->{id};
}

sub get_prefix_id {
    my ($config, $cidr, $noerr) = @_;

    my $result =
        eval { return nautobot_api_request($config, "GET", "/ipam/prefixes/?prefix=$cidr"); };
    if ($@) {
        return if $noerr;
        die "error while querying for cidr $cidr prefix id: $@\n";
    }

    my $data = @{ $result->{results} }[0];
    return $data->{id};
}

sub get_namespace_id {
    my ($config, $namespace, $noerr) = @_;

    my $result =
        eval { return nautobot_api_request($config, "GET", "/ipam/namespaces/?name=$namespace"); };
    if ($@) {
        return if $noerr;
        die "error while querying for namespace $namespace id: $@\n";
    }

    my $data = @{ $result->{results} }[0];
    return $data->{id};
}

sub get_status_id {
    my ($config, $status, $noerr) = @_;

    my $result =
        eval { return nautobot_api_request($config, "GET", "/extras/statuses/?name=$status"); };
    if ($@) {
        return if $noerr;
        die "error while querying for status $status id: $@\n";
    }

    my $data = @{ $result->{results} }[0];
    return $data->{id};
}

sub is_ip_gateway {
    my ($config, $ip, $noerr) = @_;

    my $result =
        eval { return nautobot_api_request($config, "GET", "/ipam/ip-addresses/?address=$ip"); };
    if ($@) {
        return if $noerr;
        die "error while checking if $ip is a gateway: $@\n";
    }

    my $data = @{ $result->{results} }[0];
    return $data->{description} eq 'gateway';
}

1;
