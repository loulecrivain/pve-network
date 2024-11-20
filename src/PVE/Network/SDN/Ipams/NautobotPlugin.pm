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

# implem
sub verify_api {
    my ($class, $plugin_config) = @_;

    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $namespace = $plugin_config->{namespace};
    my $headers = [ 'Authorization' => "token $token", 'Accept' => "application/json; indent=4" ];

    # check that the namespace exists AND that we have
    # indeed API access
    eval {
	PVE::Network::SDN::Ipams::NautobotPlugin::get_namespace_id($url, $namespace, $headers) // die "namespace $namespace does not exist";
    };
    if ($@) {
	die "Can't connect to nautobot api: $@";
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

1;
