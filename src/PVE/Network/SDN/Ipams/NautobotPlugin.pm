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

sub verify_api {
    my ($class, $plugin_config) = @_;

    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $headers = [ 'Authorization' => "token $token", 'Accept' => "application/json; indent=4" ];

    eval {
	PVE::Network::SDN::api_request("GET", "$url/ipam/namespaces", $headers);
    };
    if ($@) {
	die "Can't connect to nautobot api: $@";
    }
}

# helpers
sub on_update_hook {
    my ($class, $plugin_config) = @_;

    PVE::Network::SDN::Ipams::NautobotPlugin::verify_api($class, $plugin_config);
}

1;
