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

1;
