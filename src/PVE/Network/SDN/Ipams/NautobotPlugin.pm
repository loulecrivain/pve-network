package PVE::Network::SDN::Ipams::NautobotPlugin;

use strict;
use warnings;
use PVE::INotify;
use PVE::Cluster;
use PVE::Tools;

use base('PVE::Network::SDN::Ipams::NetboxPlugin');

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
    };
}

sub default_ip_status {
    return 'Active';
}

# implem

sub add_subnet {
    my ($class, $plugin_config, $subnetid, $subnet, $noerr) = @_;

    my $cidr = $subnet->{cidr};
    my $gateway = $subnet->{gateway};
    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $namespace = $plugin_config->{namespace};
    my $headers = ['Content-Type' => "application/json", 'Authorization' => "token $token", 'Accept' => "application/json"];

    my $internalid = PVE::Network::SDN::Ipams::NetboxPlugin::get_prefix_id($url, $cidr, $headers);

    #create subnet
    if (!$internalid) {
	my $namespace_id = get_namespace_id($url, $namespace, $headers);
	my $status_id = get_status_id($url, default_ip_status(), $headers);

	my $params = { prefix => $cidr, namespace => { id => $namespace_id}, status => { id => $status_id}};

	eval {
		my $result = PVE::Network::SDN::api_request("POST", "$url/ipam/prefixes/", $headers, $params);
	};
	if ($@) {
	    die "error adding subnet to ipam: $@" if !$noerr;
	}
    }
}

sub add_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $vmid, $is_gateway, $noerr) = @_;

    my $mask = $subnet->{mask};
    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $namespace = $plugin_config->{namespace};
    my $headers = ['Content-Type' => "application/json", 'Authorization' => "token $token", 'Accept' => "application/json"];

    my $namespace_id = get_namespace_id($url, $namespace, $headers);
    my $status_id = get_status_id($url, default_ip_status(), $headers);

    my $description = undef;
    if ($is_gateway) {
	$description = 'gateway'
    } elsif ($mac) {
	$description = "mac:$mac";
    }

    my $params = { address => "$ip/$mask", type => "dhcp", dns_name => $hostname, description => $description, namespace => { id => $namespace_id }, status => { id => $status_id }};

    eval {
	PVE::Network::SDN::api_request("POST", "$url/ipam/ip-addresses/", $headers, $params);
    };

    if ($@) {
	if($is_gateway) {
	    die "error adding subnet ip to ipam: ip $ip already exists: $@" if !PVE::Network::SDN::Ipams::NetboxPlugin::is_ip_gateway($url, $ip, $headers) && !$noerr;
	} else {
	    die "error adding subnet ip to ipam: ip $ip already exists: $@" if !$noerr;
	}
    }
}


sub verify_api {
    my ($class, $plugin_config) = @_;

    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $namespace = $plugin_config->{namespace};
    my $headers = ['Content-Type' => "application/json", 'Authorization' => "token $token", 'Accept' => "application/json"];

    # check that the namespace exists AND that default IP active status
    # exists AND that we have indeed API access
    eval {
	get_namespace_id($url, $namespace, $headers) // die "namespace $namespace does not exist";
	get_status_id($url, default_ip_status(), $headers) // die "default IP status ". default_ip_status() . " not found";
    };
    if ($@) {
	die "Can't use nautobot api: $@";
    }
}

sub on_update_hook {
    my ($class, $plugin_config) = @_;

    PVE::Network::SDN::Ipams::NautobotPlugin::verify_api($class, $plugin_config);
}

# helpers
sub get_namespace_id {
    my ($url, $namespace, $headers) = @_;

    my $result = PVE::Network::SDN::api_request("GET", "$url/ipam/namespaces/?q=$namespace", $headers);
    my $data = @{$result->{results}}[0];
    my $internalid = $data->{id};
    return $internalid;
}

sub get_status_id {
    my ($url, $status, $headers) = @_;

    my $result = PVE::Network::SDN::api_request("GET", "$url/extras/statuses/?q=$status", $headers);
    my $data = @{$result->{results}}[0];
    my $internalid = $data->{id};
    return $internalid;
}

1;
