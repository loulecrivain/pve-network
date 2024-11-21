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

sub verify_api {
    my ($class, $plugin_config) = @_;

    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $namespace = $plugin_config->{namespace};
    my $headers = [ 'Authorization' => "token $token", 'Accept' => "application/json; indent=4" ];

    # check that the namespace exists AND that default IP active status
    # exists AND that we have indeed API access
    eval {
	PVE::Network::SDN::Ipams::NautobotPlugin::get_namespace_id($url, $namespace, $headers) // die "namespace $namespace does not exist";
	PVE::Network::SDN::Ipams::NautobotPlugin::get_status_id($url, default_ip_status(), $headers) // die "default IP status ". default_ip_status() . " not found";
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
