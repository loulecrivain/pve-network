package PVE::Network::SDN::FrrPlugin;

use strict;
use warnings;
use PVE::Network::SDN::Plugin;
use PVE::Tools;
use PVE::INotify;
use PVE::JSONSchema qw(get_standard_option);

use base('PVE::Network::SDN::Plugin');

sub type {
    return 'frr';
}

sub plugindata {
    return {
        role => 'controller',
    };
}

sub properties {
    return {
        'asn' => {
            type => 'integer',
            description => "autonomous system number",
        },
        'peers' => {
            description => "peers address list.",
            type => 'string', format => 'ip-list'
        },
	'gateway-nodes' => get_standard_option('pve-node-list'),
        'gateway-external-peers' => {
            description => "upstream bgp peers address list.",
            type => 'string', format => 'ip-list'
        },
    };
}

sub options {

    return {
	'uplink-id' => { optional => 0 },
        'asn' => { optional => 0 },
        'peers' => { optional => 0 },
	'gateway-nodes' => { optional => 1 },
	'gateway-external-peers' => { optional => 1 },
    };
}

# Plugin implementation
sub generate_controller_config {
    my ($class, $plugin_config, $router, $id, $uplinks, $config) = @_;

    my @peers = split(',', $plugin_config->{'peers'}) if $plugin_config->{'peers'};

    my $asn = $plugin_config->{asn};
    my $uplink = $plugin_config->{'uplink-id'};
    my $gatewaynodes = $plugin_config->{'gateway-nodes'};
    my @gatewaypeers = split(',', $plugin_config->{'gateway-external-peers'}) if $plugin_config->{'gateway-external-peers'};

    return if !$asn;

    my $iface = "uplink$uplink";
    my $ifaceip = "";

    if($uplinks->{$uplink}->{name}) {
	$iface = $uplinks->{$uplink}->{name};
        $ifaceip = PVE::Network::SDN::Plugin::get_first_local_ipv4_from_interface($iface);
    }

    my $is_gateway = undef;
    my $local_node = PVE::INotify::nodename();

    foreach my $gatewaynode (PVE::Tools::split_list($gatewaynodes)) {
        $is_gateway = 1 if $gatewaynode eq $local_node;
    }

    my @router_config = ();

    push @router_config, "bgp router-id $ifaceip";
    push @router_config, "no bgp default ipv4-unicast";
    push @router_config, "coalesce-time 1000";

    foreach my $address (@peers) {
	next if $address eq $ifaceip;
	push @router_config, "neighbor $address remote-as $asn";
    }

    if ($is_gateway) {
	foreach my $address (@gatewaypeers) {
	    push @router_config, "neighbor $address remote-as external";
	}
    }
    push(@{$config->{frr}->{router}->{"bgp $asn"}->{""}}, @router_config);

    @router_config = ();
    foreach my $address (@peers) {
	next if $address eq $ifaceip;
	push @router_config, "neighbor $address activate";
    }
    push @router_config, "advertise-all-vni";
    push(@{$config->{frr}->{router}->{"bgp $asn"}->{"address-family"}->{"l2vpn evpn"}}, @router_config);

    if ($is_gateway) {

        @router_config = ();
        #import /32 routes of evpn network from vrf1 to default vrf (for packet return)
        #frr 7.1 tag is bugged -> works fine with 7.1 stable branch(20190829-02-g6ba76bbc1)
        #https://github.com/FRRouting/frr/issues/4905
	foreach my $address (@gatewaypeers) {
	    push @router_config, "neighbor $address activate";
	}
        push(@{$config->{frr}->{router}->{"bgp $asn"}->{"address-family"}->{"ipv4 unicast"}}, @router_config);
        push(@{$config->{frr}->{router}->{"bgp $asn"}->{"address-family"}->{"ipv6 unicast"}}, @router_config);

    }

    return $config;
}

sub generate_controller_transport_config {
    my ($class, $plugin_config, $router, $id, $uplinks, $config) = @_;

    my $vrf = $plugin_config->{'vrf'};
    my $vrfvxlan = $plugin_config->{'vrf-vxlan'};
    my $asn = $router->{asn};
    my $gatewaynodes = $router->{'gateway-nodes'};

    return if !$vrf || !$vrfvxlan || !$asn;

    #vrf
    my @router_config = ();
    push @router_config, "vni $vrfvxlan";
    push(@{$config->{frr}->{vrf}->{"$vrf"}}, @router_config);

    @router_config = ();

    my $is_gateway = undef;
    my $local_node = PVE::INotify::nodename();

    foreach my $gatewaynode (PVE::Tools::split_list($gatewaynodes)) {
	$is_gateway = 1 if $gatewaynode eq $local_node;
    }

    if ($is_gateway) {

	@router_config = ();
	#import /32 routes of evpn network from vrf1 to default vrf (for packet return)
	#frr 7.1 tag is bugged -> works fine with 7.1 stable branch(20190829-02-g6ba76bbc1)
	#https://github.com/FRRouting/frr/issues/4905
	push @router_config, "import vrf $vrf";
	push(@{$config->{frr}->{router}->{"bgp $asn"}->{"address-family"}->{"ipv4 unicast"}}, @router_config);
	push(@{$config->{frr}->{router}->{"bgp $asn"}->{"address-family"}->{"ipv6 unicast"}}, @router_config);

	@router_config = ();
	#redistribute connected to be able to route to local vms on the gateway
	push @router_config, "redistribute connected";
	push(@{$config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{"address-family"}->{"ipv4 unicast"}}, @router_config);
	push(@{$config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{"address-family"}->{"ipv6 unicast"}}, @router_config);

	@router_config = ();
	#add default originate to announce 0.0.0.0/0 type5 route in evpn
	push @router_config, "default-originate ipv4";
	push @router_config, "default-originate ipv6";
	push(@{$config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{"address-family"}->{"l2vpn evpn"}}, @router_config);
    }

    return $config;
}

sub on_delete_hook {
    my ($class, $routerid, $sdn_cfg) = @_;

    # verify that transport is associated to this router
    foreach my $id (keys %{$sdn_cfg->{ids}}) {
        my $sdn = $sdn_cfg->{ids}->{$id};
        die "router $routerid is used by $id"
            if (defined($sdn->{router}) && $sdn->{router} eq $routerid);
    }
}

sub on_update_hook {
    my ($class, $routerid, $sdn_cfg) = @_;

    # verify that asn is not already used by another router
    my $asn = $sdn_cfg->{ids}->{$routerid}->{asn};
    foreach my $id (keys %{$sdn_cfg->{ids}}) {
	next if $id eq $routerid;
        my $sdn = $sdn_cfg->{ids}->{$id};
        die "asn $asn is already used by $id"
            if (defined($sdn->{asn}) && $sdn->{asn} eq $asn);
    }
}

sub sort_frr_config {
    my $order = {};
    $order->{''} = 0;
    $order->{'vrf'} = 1;
    $order->{'ipv4 unicast'} = 1;
    $order->{'ipv6 unicast'} = 2;
    $order->{'l2vpn evpn'} = 3;

    my $a_val = 100;
    my $b_val = 100;

    $a_val = $order->{$a} if defined($order->{$a});
    $b_val = $order->{$b} if defined($order->{$b});

    if($a =~ /bgp (\d+)$/) {
	$a_val = 2;
    }

    if($b =~ /bgp (\d+)$/) {
	$b_val = 2;
    }

    return $a_val <=> $b_val;
}

sub generate_frr_recurse{
   my ($final_config, $content, $parentkey, $level) = @_;

   my $keylist = {};
   $keylist->{vrf} = 1;
   $keylist->{'address-family'} = 1;
   $keylist->{router} = 1;

   my $exitkeylist = {};
   $exitkeylist->{vrf} = 1;
   $exitkeylist->{'address-family'} = 1;

   #fix me, make this generic
   my $paddinglevel = undef;
   if($level == 1 || $level == 2) {
     $paddinglevel = $level - 1;
   } elsif ($level == 3 || $level ==  4) {
     $paddinglevel = $level - 2;
   }

   my $padding = "";
   $padding = ' ' x ($paddinglevel) if $paddinglevel;

   if (ref $content eq ref {}) {
	foreach my $key (sort sort_frr_config keys %$content) {
	    if ($parentkey && defined($keylist->{$parentkey})) {
	 	    push @{$final_config}, $padding."!";
	 	    push @{$final_config}, $padding."$parentkey $key";
	    } else {
	 	    push @{$final_config}, $padding."$key" if $key ne '' && !defined($keylist->{$key});
	    }

	    my $option = $content->{$key};
	    generate_frr_recurse($final_config, $option, $key, $level+1);

	    push @{$final_config}, $padding."exit-$parentkey" if $parentkey && defined($exitkeylist->{$parentkey});
	}
    }

    if (ref $content eq 'ARRAY') {
	foreach my $value (@$content) {
	    push @{$final_config}, $padding."$value";
	}
    }
}

sub write_controller_config {
    my ($class, $plugin_config, $config) = @_;

    my $final_config = [];
    push @{$final_config}, "log syslog informational";
    push @{$final_config}, "!";

    generate_frr_recurse($final_config, $config->{frr}, undef, 0);

    push @{$final_config}, "!";
    push @{$final_config}, "line vty";
    push @{$final_config}, "!";

    my $rawconfig = join("\n", @{$final_config});


    return if !$rawconfig;
    return if !-d "/etc/frr";

    my $frr_config_file = "/etc/frr/frr.conf";

    my $writefh = IO::File->new($frr_config_file,">");
    print $writefh $rawconfig;
    $writefh->close();
}

1;


