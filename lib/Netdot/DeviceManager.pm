package Netdot::DeviceManager;

=head1 NAME

Netdot::DeviceManager - Device-related Functions for Netdot

=head1 SYNOPSIS

  use Netdot::DeviceManager

  $dm = Netdot::DeviceManager->new();  

    # See if device exists
    my ($c, $d) = $dm->find_dev($host);
    
    # Fetch SNMP info
    my $dev = $dm->get_dev_info($host, $comstr);
    
    # Update database
    $o = $dm->update_device(%argv);

=cut

use lib "<<Make:LIB>>";
use Data::Dumper;

use lib "<<Make:NVLIB>>";
use NetViewer::RRD::SNMP::NV;

use base qw( Netdot::IPManager Netdot::DNSManager );
use strict;

#Be sure to return 1
1;

=head1 METHODS

=head2 new - Create a new DeviceManager object
 
    $dm = Netdot::DeviceManager->new(logfacility   => $logfacility,
				     snmpversion   => $version,
				     community     => $comstr,
				     retries       => $retries,
				     timeout       => $timeout,
				     );

=cut

sub new { 
    my ($proto, %argv) = @_;
    my $class = ref( $proto ) || $proto;
    my $self = {};
    bless $self, $class;
    
    $self = $self->SUPER::new( %argv );

    $self->{'_snmpversion'}   = $argv{'snmpversion'}   || $self->{config}->{'DEFAULT_SNMPVERSION'};
    $self->{'_snmpcommunity'} = $argv{'community'}     || $self->{config}->{'DEFAULT_SNMPCOMMUNITY'};
    $self->{'_snmpretries'}   = $argv{'retries'}       || $self->{config}->{'DEFAULT_SNMPRETRIES'};
    $self->{'_snmptimeout'}   = $argv{'timeout'}       || $self->{config}->{'DEFAULT_SNMPTIMEOUT'};

    $self->{nv} = NetViewer::RRD::SNMP::NV->new(aliases     => "<<Make:PREFIX>>/etc/categories",
						snmpversion => $self->{'_snmpversion'},
						community   => $self->{'_snmpcommunity'},
						retries     => $self->{'_snmpretries'},
						timeout     => $self->{'_snmptimeout'},
						);
    wantarray ? ( $self, '' ) : $self; 
}

=head2 output -  Store and get appended output for interactive use
    
    $dm->output("Doing this and that");
    print $dm->output();

=cut
   
sub output {
	my $self = shift;
    if (@_){ 
	$self->{'_output'} .= shift;
	$self->{'_output'} .= "\n";
    }
    return $self->{'_output'};
}

=head2 find_dev - Perform some preliminary checks to determine if a device exists

    my ($c, $d) = $dm->find_dev($host);

=cut

sub find_dev {
    my ($self, $host) = @_;
    my ($device, $comstr);
    $self->error(undef);
    $self->_clear_output();

    if ($device = $self->getdevbyname($host)){
	my $msg = sprintf("Device %s exists in DB.  Will try to update.", $host);
	$self->debug( loglevel => 'LOG_NOTICE',
		      message  => $msg );
	$comstr = $device->community;
	$self->debug( loglevel => 'LOG_DEBUG',
		      message  => "Device has community: %s",
		      args     => [$comstr] );
    }elsif($self->getrrbyname($host)){
	my $msg = sprintf("Name %s exists but Device not in DB.  Will try to create.", $host);
	$self->debug( loglevel => 'LOG_NOTICE',
		      message  => $msg );
    }elsif(my $ip = $self->searchblocks_addr($host)){
	if ( $ip->interface && ($device = $ip->interface->device) ){
	    my $msg = sprintf("Device with address %s exists in DB. Will try to update.", $ip->address);
	    $self->debug( loglevel => 'LOG_NOTICE',
			  message  => $msg );
	    $comstr = $device->community;
	    $self->debug( loglevel => 'LOG_DEBUG',
			  message  => "Device has community: %s",
			  args     => [$comstr] );
	}else{
	    my $msg = sprintf("Address %s exists but Device not in DB.  Will try to create.", $host);
	    $self->debug( loglevel => 'LOG_NOTICE',
			  message  => $msg );
	}
    }else{
	my $msg = sprintf("Device %s not in DB.  Will try to create.", $host);
	$self->debug( loglevel => 'LOG_NOTICE',
		      message  => $msg );
    }
    return ($comstr, $device);
}

=head2 update_device - Insert new Device/Update Device in Database

 This method can be called from Netdot s web components or 
 from independent scripts.  Should be able to update existing 
 devices or create new ones

  Required Args:
    host:   Name or ip address of host
    dev:    Hashref of device information
  Optional Args:
    comstr: SNMP community string (default "public")
    device: Existing 'Device' object 
    user:   Netdot user calling the method 
  Returns:
    Device object


=cut

sub update_device {
    my ($self, %argv) = @_;
    my ($host, $comstr, %dev);
    $self->_clear_output();

    unless ( ($host = $argv{host}) && (%dev = %{$argv{dev}}) ){
	$self->error( sprintf("Missing required arguments") );
	$self->debug(loglevel => 'LOG_ERR',
		     message => $self->error);
	return 0;
    }
    my $device = $argv{device} || "";
    $argv{owner}               ||= 0;
    $argv{used_by}             ||= 0;
    $argv{site}                ||= 0;
    $argv{user}                ||= 0;

    my %devtmp;

    $devtmp{sysdescription} = $dev{sysdescription} || "";
    $devtmp{community}      = $argv{comstr}        || "";

    my @cls;
    my %ifs;
    my %bgppeers;
    my %dbips;

    if ( $device ){
	################################################     
	# Keep a hash of stored Interfaces for this Device
	map { $ifs{ $_->id } = $_ } $device->interfaces();

	# Get all stored IPs 
	map { $dbips{$_->address} = $_->id } map { $ifs{$_}->ips() } keys %ifs;

	# Remove invalid dependencies
	foreach my $ifid (keys %ifs){
	    my $if = $ifs{$ifid};
	    foreach my $dep ( $if->parents() ){		
		unless ( $dep->parent->device ){
		    $self->debug( loglevel => 'LOG_NOTICE',
				  message  => "%s: Interface %s,%s has invalid parent %s. Removing.",
				  args => [$host, $if->number, $if->name, $dep->parent] );
		    $self->remove(table=>"InterfaceDep", id => $dep);
		    next;
		}
	    }
	    foreach my $dep ( $if->children() ){
		unless ( $dep->child->device ){
		    $self->debug( loglevel => 'LOG_NOTICE',
				  message  => "%s: Interface %s,%s has invalid child %s. Removing.",
				  args => [$host, $if->number, $if->name,$dep->child] );
		    $self->remove(table=>"InterfaceDep", id => $dep);
		    next;
		}
	    }
	}

    }else{
	# Device does not exist in DB
	$devtmp{owner}        = $argv{owner};
	$devtmp{used_by}      = $argv{used_by};
	$devtmp{site}         = $argv{site};

	if ( $argv{user} ){
	    $devtmp{info}    = "Added to Netdot by $argv{user}";
	}
	
	if ( ! $argv{contacts} ){
	    my $default_cl;
	    if ( $default_cl = (ContactList->search(name=>$self->{config}->{DEFAULT_CONTACTLIST}))[0] ){
		push @cls, $default_cl;
	    }else{
		$self->debug( loglevel => 'LOG_ERR',
			      message  => "%s: Default Contact List not found: %s",
			      args     => [$host, $self->{config}->{DEFAULT_CONTACTLIST}] );
	    }
	}else{
	    if (!ref($argv{contacts})){
		# Only one was selected, so it is a scalar
		push @cls, $argv{contacts};
	    }elsif( ref($argv{contacts}) eq "ARRAY" ){
		@cls = @{ $argv{contacts} };
	    }else{
		$self->debug( loglevel => 'LOG_ERR',
			      message  => "%s: A contacts arg was passed, but was not valid: %s",
			      args     => [$host, $argv{contacts}] );
	    }
	}
	
    }

    ##############################################
    # Make sure name is in DNS

    my $rr;
    if ( $rr = $self->getrrbyname($host) ) {
	my $msg = sprintf("Name %s exists in DB. Pointing to it", $host);
	$self->debug( loglevel => 'LOG_NOTICE',
		      message  => $msg);
	$devtmp{name} = $rr;
    }elsif($device && $device->name && $device->name->name){
	my $msg = sprintf("Device %s exists in DB as %s. Keeping existing name", $host, $device->name->name);
	$self->debug( loglevel => 'LOG_NOTICE',
		      message  => $msg);
	$devtmp{name} = $device->name;
	$rr = $device->name;
	$host = $device->name->name;
    }else{
	# Check if hostname is an ip address (v4 or v6)
	if ( $host =~ /\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/ ||
	     $host =~ /:/){
	    # It is, so look it up
	    my $name;
	    if ( $name = $self->resolve_ip($host) ){
		my $msg = sprintf("Name associated with %s: %s", $host, $name );
		$self->debug( loglevel => 'LOG_DEBUG',
			      message  => $msg
			      );	    
		# Use this name instead
		$host = $name;
	    }else{
		my $msg = sprintf("%s", $self->error);
		$self->debug( loglevel => 'LOG_ERR',
			      message  => $msg
			      );	    
		$self->error($msg);	
	    }
	}
	if ($rr = $self->insert_rr(name => $host)){

	    my $msg = sprintf("Inserted DNS name %s into DB", $host);
	    $self->debug( loglevel => 'LOG_NOTICE',
			  message  => $msg,
			  );	    
	    $self->output($msg);
	    $devtmp{name} = $rr;
	}else{
	    my $msg = sprintf("Could not insert DNS entry %s: %s", $host, $self->error);
	    $self->debug( loglevel => 'LOG_ERR',
			  message  => $msg
			  );	    
	    $self->error($msg);
	    return 0;
	}
    }
    # We'll use these later when adding A records for each address
    my %hostnameips;
    if (my @addrs = $self->resolve_name($rr->name)){
	map { $hostnameips{$_} = "" } @addrs;
	
	my $msg = sprintf("%s: Addresses associated with hostname: %s", $host, (join ", ", keys %hostnameips) );
	$self->debug( loglevel => 'LOG_DEBUG',
		      message  => $msg
		      );	    
    }else{
	my $msg = sprintf("%s", $self->error);
	$self->debug( loglevel => 'LOG_NOTICE',
		      message  => $msg
		      );	    
	$self->error($msg);	
    }
    ###############################################
    # Try to assign Product based on SysObjectID

    if( $dev{sysobjectid} ){
	if ( my $prod = (Product->search( sysobjectid => $dev{sysobjectid} ))[0] ) {
	    my $msg = sprintf("%s: SysID matches existing %s", $host, $prod->name);
	    $self->debug( loglevel => 'LOG_INFO',message  => $msg );
	    $devtmp{productname} = $prod->id;
	    
	}else{
	    ###############################################
	    # Create a new product entry
	    my $msg = sprintf("%s: New product with SysID %s.  Adding to DB", $host, $dev{sysobjectid});
	    $self->debug( loglevel => 'LOG_INFO', message  => $msg );
	    $self->output( $msg );	
	    
	    ###############################################
	    # Check if Manufacturer Entity exists or can be added
	    
	    my $oid = $dev{enterprise};
	    my $ent;
	    if($ent = (Entity->search( oid => $oid ))[0] ) {
		$self->debug( loglevel => 'LOG_INFO',
			      message  => "Manufacturer OID matches %s", 
			      args     => [$ent->name]);
	    }else{
		$self->debug( loglevel => 'LOG_INFO',
			      message  => "Entity with Enterprise OID %s not found. Creating", 
			      args => [$oid]);
		my $t;
		unless ( $t = (EntityType->search(name => "Manufacturer"))[0] ){
		    $t = 0; 
		}
		my $entname = $dev{manufacturer} || $oid;
		if ( ($ent = $self->insert(table => 'Entity', 
					   state => { name => $entname,
						      oid  => $oid,
						      type => $t }) ) ){
		    my $msg = sprintf("Created Entity: %s. ", $entname);
		    $self->debug( loglevel => 'LOG_NOTICE',
				  message  => $msg );		
		}else{
		    $self->debug( loglevel => 'LOG_ERR',
				  message  => "Could not create new Entity: %s: %s",
				  args     => [$entname, $self->error],
				  );
		    $ent = 0;
		}
	    }
	    ###############################################
	    # Try to guess product type
	    # First based on name, then on some key oids
	    
	    my ($type, $typename);
	    foreach my $str ( keys %{ $self->{config}->{DEV_NAME2TYPE} } ){
		if ( $host =~ /$str/ ){
		    $typename = $self->{config}->{DEV_NAME2TYPE}->{$str};
		}
	    } 
	    if ( $typename ){
		$type = (ProductType->search(name=>$typename))[0];	    
	    }else{
		if ( $dev{router} ){
		    $type = (ProductType->search(name=>"Router"))[0];
		}elsif ( $dev{hub} ){
		    $type = (ProductType->search(name=>"Hub"))[0];
		}elsif ( $dev{dot11} ){
		    $type = (ProductType->search(name=>"Access Point"))[0];
		}elsif ( scalar $dev{interface} ){
		    $type = (ProductType->search(name=>"Switch"))[0];
		}
	    }
	    my ( $typeid, $dbtypename );
	    if ( ref($type) ){
		$typeid   = $type->id;
		$dbtypename = $type->name;
	    }else{
		$typeid   = 0;
		$dbtypename = 'unknown';
	    }
	    my %prodtmp = ( name         => $dev{productname} || $dev{sysobjectid},
			    description  => $dev{productname} || "",
			    sysobjectid  => $dev{sysobjectid},
			    type         => $typeid,
			    manufacturer => $ent,
			    );
	    my $newprodid;
	    if ( ($newprodid = $self->insert(table => 'Product', state => \%prodtmp)) ){
		my $msg = sprintf("%s: Created product: %s.  Guessing type is %s.", $host, $prodtmp{name}, $dbtypename);
		$self->debug( loglevel => 'LOG_NOTICE',
			      message  => $msg );		
		$self->output($msg);
		$devtmp{productname} = $newprodid;
	    }else{
		$self->debug( loglevel => 'LOG_ERR',
			      message  => "%s: Could not create new Product: %s: %s",
			      args     => [$host, $prodtmp{name}, $self->error],
			      );		
		$devtmp{productname} = 0;
	    }
	}
    }else{
	$devtmp{productname} = 0;
    }

    ###############################################
    # Update/add PhsyAddr for Device
    
    if( defined $dev{physaddr} ) {
	# Look it up
	if ( my $phy = (PhysAddr->search(address => $dev{physaddr}))[0] ){
	    if ( my $otherdev = ($phy->devices)[0] ){
		#
		# At least another device exists that has that address
		# 
		if ( ! $device || ( $device && $device->id != $otherdev->id ) ){
		    my $name = (defined($otherdev->name->name))? $otherdev->name->name : $otherdev->id;
		    $self->error( sprintf("%s: PhysAddr %s belongs to existing device: %s. Aborting", 
					  $host, $dev{physaddr}, $name ) ); 
		    $self->debug( loglevel => 'LOG_ERR',
				  message  => $self->error,
				  );
		    return 0;
		}
	    }else{
		#
		# The address exists but it's not the base bridge address of any other device
		# (maybe discovered in fw tables/arp cache)
		# Just point to it from this Device
		#
		$devtmp{physaddr} = $phy->id;
		$self->update( object => $phy, 
			       state  => {last_seen => $self->timestamp },
			       );
	    }
	    $self->debug( loglevel => 'LOG_INFO',
			  message  => "%s, Pointing to existing %s as base bridge address",
			  args => [$host, $dev{physaddr}],
			  );		
	    #
	    # address is new.  Add it
	    #
	}else{
	    my %phaddrtmp = ( address => $dev{physaddr},
			      first_seen => $self->timestamp,
			      last_seen => $self->timestamp,
			      );
	    my $newphaddr;
	    if ( ! ($newphaddr = $self->insert(table => 'PhysAddr', state => \%phaddrtmp)) ){
		$self->debug( loglevel => 'LOG_ERR',
			      message  => "%s, Could not create new PhysAddr: %s: %s",
			      args => [$host, $phaddrtmp{address}, $self->error],
			      );
		$devtmp{physaddr} = 0;
	    }else{
		$self->debug( loglevel => 'LOG_NOTICE',
			      message  => "%s: Added new PhysAddr: %s",
			      args => [$host, $phaddrtmp{address}],
			      );		
		$devtmp{physaddr} = $newphaddr;
	    }
	}
    }else{
	$self->debug( loglevel => 'LOG_INFO',
		      message  => "%s did not return dot1dBaseBridgeAddress",
		      args => [$host],
		      );
	$devtmp{physaddr} = 0;
    }
    ###############################################
    # Serial Number
    
    if( defined $dev{serialnumber} ) {
	if ( my $otherdev = (Device->search(serialnumber => $dev{serialnumber}))[0] ){
	    if ( ! $device || ($device && $device->id != $otherdev->id) ){
		my $othername = (defined $otherdev->name && defined $otherdev->name->name) ? 
		    $otherdev->name->name : $otherdev->id;
		$self->error( sprintf("%s: S/N %s belongs to existing device: %s. Aborting.", 
				      $host, $dev{serialnumber}, $othername) ); 
		$self->debug( loglevel => 'LOG_ERR',
			      message  => $self->error,
			      );
		return 0;
	    }
	}
	$devtmp{serialnumber} = $dev{serialnumber};
    }else{
	$self->debug( loglevel => 'LOG_INFO',
		      message  => "%s: Did not return serial number",
		      args     => [$host]);

	# If device exists in DB, and we have a serial number, remove it.
	# Most likely it's being replaced with a different unit

	if ( $device && $device->serialnumber ){
	    $devtmp{serialnumber} = "";
	}
    }
    ###############################################
    # Basic BGP info
    if( defined $dev{bgplocalas} ){
	$self->debug( loglevel => 'LOG_DEBUG',
		      message  => "BGP Local AS is %s", 
		      args     => [$dev{bgplocalas}] );
	
	$devtmp{bgplocalas} = $dev{bgplocalas};
    }
    if( defined $dev{bgpid} ){
	$self->debug( loglevel => 'LOG_DEBUG',
		      message  => "BGP ID is %s", 
		      args     => [$dev{id}] );
	
	$devtmp{bgpid} = $dev{bgpid};
    }
    ###############################################
    #
    # Update/Add Device
    #
    ###############################################
    
    if ( $device ){
	$devtmp{lastupdated} = $self->timestamp;
	unless( $self->update( object => $device, state => \%devtmp ) ) {
	    $self->error( sprintf("%s: Error updating: %s", $host, $self->error) ); 
	    $self->debug( loglevel => 'LOG_ERR',
			  message  => $self->error,
			  );
	    return 0;
	}
    }else{
	# Some Defaults
	# 
	$devtmp{monitored}        = 1;
	$devtmp{snmp_managed}     = 1;
	$devtmp{canautoupdate}    = 1;
	$devtmp{customer_managed} = 0;
	$devtmp{natted}           = 0;
	$devtmp{dateinstalled}    = $self->timestamp;
	my $newdevid;
	unless( $newdevid = $self->insert( table => 'Device', state => \%devtmp ) ) {
	    $self->error( sprintf("%s: Error creating: %s", $host, $self->error) ); 
	    $self->debug( loglevel => 'LOG_ERR',
			  message  => $self->error );
	    return 0;
	}
	$self->debug( loglevel => 'LOG_DEBUG', 
		      message  =>  "%s: Created Device id %s",
		      args     => [$host, $newdevid] );

	$device = Device->retrieve($newdevid);
    }
    
    ##############################################
    # Assign contact lists
    
    foreach my $cl ( @cls ){
	my $dcid;
	unless ( $dcid = $self->insert(table=>"DeviceContacts", 
				       state=>{device=>$device->id, contactlist=>$cl} ) ){
	    $self->error( sprintf("%s: Error creating DeviceContact: %s", $host, $self->error) ); 
	    $self->debug( loglevel => 'LOG_ERR', message  => $self->error );
	    return 0;
	}
	$self->debug( loglevel => 'LOG_DEBUG', 
		      message  =>  "%s: Created DeviceContact id %s",
		      args     => [$host, $dcid] );
    }
		     
    ##############################################
    #
    # for each interface just discovered...
    #
    ##############################################
    
    my (%newips, %dbvlans, %ifvlans, @nonrrs);
    
    my %IFFIELDS = ( number           => "",
		     name             => "",
		     type             => "",
		     description      => "",
		     speed            => "",
		     admin_status     => "",
		     oper_status      => "",
		     admin_duplex     => "",
		     oper_duplex      => "");

    foreach my $newif ( sort { $a <=> $b } keys %{ $dev{interface} } ) {

	############################################
	# set up IF state data
	my( %iftmp, $if );
	$iftmp{device} = $device->id;
	
	foreach my $field ( keys %{ $dev{interface}{$newif} } ){
	    if (exists $IFFIELDS{$field}){
		$iftmp{$field} = $dev{interface}{$newif}{$field};
	    }
	}

	###############################################
	# Update/add PhsyAddr for Interface
	if (defined (my $addr = $dev{interface}{$newif}{physaddr})){
	    # Look it up
	    if (my $phy = (PhysAddr->search(address => $addr))[0] ){
		#
		# The address exists 
		# Just point to it from this Interface
		#
		$iftmp{physaddr} = $phy->id;
		$self->update( object => $phy, 
			     state => {last_seen => $self->timestamp} );
		$self->debug( loglevel => 'LOG_INFO',
			      message  => "%s: Interface %s,%s has existing PhysAddr %s",
			      args => [$host, $iftmp{number}, $iftmp{name}, $addr],
			      );		
		#
		# address is new.  Add it
		#
	    }else{
		my %phaddrtmp = ( address    => $addr,
				  first_seen => $self->timestamp,
				  last_seen  => $self->timestamp,
				  );
		my $newphaddr;
		if ( ! ($newphaddr = $self->insert(table => 'PhysAddr', state => \%phaddrtmp)) ){
		    $self->debug( loglevel => 'LOG_ERR',
				  message  => "%s: Could not create PhysAddr %s for Interface %s,%s: %s",
				  args     => [$host, $phaddrtmp{address}, $iftmp{number}, $iftmp{name}, 
					       $self->error],
				  );
		    $iftmp{physaddr} = 0;
		}else{
		    $self->debug( loglevel => 'LOG_INFO',
				  message  => "%s: Added new PhysAddr %s for Interface %s,%s",
				  args => [$host, $phaddrtmp{address}, $iftmp{number}, $iftmp{name}],
				  );		
		    $iftmp{physaddr} = $newphaddr;
		}
	    }
	}
	############################################
	# Add/Update interface
	if ( $if = (Interface->search(device => $device->id, 
				      number => $iftmp{number}))[0] ) {
	    delete( $ifs{ $if->id } );

	    # Check if description can be overwritten
	    if ( ! $if->overwrite_descr ){
		delete $iftmp{description};
	    }
	    # Update
	    unless( $self->update( object => $if, state => \%iftmp ) ) {
		my $msg = sprintf("%s: Could not update Interface %s,%s: ", 
				  $host, $iftmp{number}, $iftmp{name}, $self->error);
		$self->debug( loglevel => 'LOG_ERR',
			      message  => $msg,
			      );
		$self->output($msg);
		next;
	    }
	} else {
	    # Interface does not exist.  Add it.
	    
	    # Set some defaults
	    $iftmp{speed}           ||= 0; #can't be null
	    $iftmp{monitored}       ||= $self->{config}->{IF_MONITORED};
	    $iftmp{snmp_managed}    ||= $self->{config}->{IF_SNMP};
	    $iftmp{overwrite_descr} ||= $self->{config}->{IF_OVERWRITE_DESCR};
	    
	    my $unkn = (MonitorStatus->search(name=>"Unknown"))[0];
	    $iftmp{monitorstatus} = ( $unkn ) ? $unkn->id : 0;
	    
	    if ( ! (my $ifid = $self->insert( table => 'Interface', 
					      state => \%iftmp )) ) {
		my $msg = sprintf("%s: Error inserting Interface %s,%s: %s", 
			       $host, $iftmp{number}, $iftmp{name}, $self->error);
		$self->debug( loglevel => 'LOG_ERR',
			      message  => $msg,
			      );
		$self->output($msg);
		next;
	    }else{
		unless( $if = Interface->retrieve($ifid) ) {
		    my $msg = sprintf("%s: Couldn't retrieve Interface id %s", $host, $ifid);
		    $self->debug( loglevel => 'LOG_ERR',
				  message  => $msg );
		    $self->output($msg);
		    next;
		}
		my $msg = sprintf("%s: Inserted Interface %s,%s ", 
				  $host, $iftmp{number}, $iftmp{name} );
		$self->debug( loglevel => 'LOG_NOTICE',
			      message  => $msg,
			      );
		$self->output($msg);
	    }
	    
	}
	################################################################
	# Get all stored VLAN memberships (these are join tables);
	#
	map { $dbvlans{$_->id} = '' } $if->vlans();

	##############################################
	# Add/Update VLANs

	foreach my $vid ( keys %{ $dev{interface}{$newif}{vlans} } ){
	    my $vname = $dev{interface}{$newif}{vlans}{$vid};
	    my $vo;
	    # look it up
	    unless ($vo = (Vlan->search(vid =>$vid))[0]){
		#create
		if ( ! (my $vobjid = $self->insert(table => "Vlan", state => { vid => $vid, description => $vname } ) ) ) {
		    my $msg = sprintf("%s: Could not insert Vlan %s: %s", 
				      $host, $vo->description, $self->error);
		    $self->debug( loglevel => 'LOG_ERR',
				  message  => $msg,
				  );
		    $self->output($msg);
		    next;
		}else {
		    $vo = Vlan->retrieve($vobjid);
		    my $msg = sprintf("%s: Inserted VLAN %s", $host, $vo->description);
		    $self->debug( loglevel => 'LOG_NOTICE',
				  message  => $msg,
				  );
		    $self->output($msg);
		    next;
		}
	    }

	    # verify membership
	    #
	    my %ivtmp = ( interface => $if->id, vlan => $vo->id );
	    my $iv;
	    unless ( $iv = (InterfaceVlan->search(\%ivtmp))[0] ){
		unless ( $iv = $self->insert(table => "InterfaceVlan", state => \%ivtmp ) ){
		    my $msg = sprintf("%s: Could not insert InterfaceVlan join %s:%s: %s", 
				      $host, $if->name, $vo->vid, $self->error);
		    $self->debug( loglevel => 'LOG_ERR',
				  message  => $msg,
				  );
		    $self->output($msg);
		}else{
		    my $msg = sprintf("%s: Assigned Interface %s,%s to VLAN %s", 
				      $host, $if->number, $if->name, $vo->description);
		    $self->debug( loglevel => 'LOG_NOTICE',
				  message  => $msg,
				  );
		}
	    }else {
		my $msg = sprintf("%s: Interface %s,%s already member of vlan %s", 
				  $host, $if->number, $if->name, $vo->vid);
		$self->debug( loglevel => 'LOG_DEBUG',
			      message  => $msg,
			      );
		delete $dbvlans{$iv->id};
	    }
	}

	################################################################
	# Add/Update IPs
	
	if( exists( $dev{interface}{$newif}{ips} ) && ! $device->natted ) {	    

	    foreach my $newip ( sort keys %{ $dev{interface}{$newif}{ips} } ){
		my( $maskobj, $subnet, $ipdbobj );
		my $version = ($newip =~ /:/) ? 6 : 4;
		my $prefix = ($version == 6) ? 128 : 32;

		########################################################
		# Create subnet if device is a router (ipForwarding true)
		# and addsubnets flag is on

		if ( $dev{router} && $argv{addsubnets}){
		    my $newmask;
		    if ( $newmask = $dev{interface}{$newif}{ips}{$newip} ){
			my $subnetaddr = $self->getsubnetaddr($newip, $newmask);
			if ( $subnetaddr ne $newip ){
			    if ( ! ($self->searchblocks_addr($subnetaddr, $newmask)) ){
				my %state = (address     => $subnetaddr, 
					     prefix      => $newmask, 
					     statusname  => "Subnet");
				# Check if subnet should inherit device info
				if ( $argv{subnets_inherit} ){
				    $state{owner}   = $device->owner;
				    $state{used_by} = $device->used_by;
				}
				unless( $self->insertblock(%state) ){
				    my $msg = sprintf("%s: Could not insert Subnet %s/%s: %s", 
						      $host, $subnetaddr, $newmask, $self->error);
				    $self->debug(loglevel => 'LOG_ERR',
						 message  => $msg );
				}else{
				    my $msg = sprintf("%s: Created Subnet %s/%s", $host, $subnetaddr, $newmask);
				    $self->debug(loglevel => 'LOG_NOTICE',
						 message  => $msg );
				    $self->output($msg);
				}
			    }else{
				my $msg = sprintf("%s: Subnet %s/%s already exists", $host, $subnetaddr, $newmask);
				$self->debug( loglevel => 'LOG_DEBUG',
					      message  => $msg );
			    }
			}else{
			    # do nothing
			    # This is probably a /32 address (loopback interface)
			}
		    }
		}
		# 
		# Keep all discovered ips in a hash
		$newips{$newip} = $if;
		my $ipobj;
		if ( my $ipid = $dbips{$newip} ){
		    #
		    # update
		    my $msg = sprintf("%s: IP %s/%s exists. Updating", $host, $newip, $prefix);
		    $self->debug( loglevel => 'LOG_DEBUG',
				  message  => $msg );
		    delete( $dbips{$newip} );
		    
		    unless( $ipobj = $self->updateblock(id           => $ipid, 
							statusname   => "Static",
							interface    => $if->id )){
			my $msg = sprintf("%s: Could not update IP %s/%s: %s", $host, $newip, $prefix, $self->error);
			$self->debug( loglevel => 'LOG_ERR',
				      message  => $msg );
			$self->output($msg);
			next;
		    }

		}elsif ( $ipobj = $self->searchblocks_addr($newip) ){
		    # IP exists but not linked to this interface
		    # update
		    my $msg = sprintf("%s: IP %s/%s exists but not linked to %s. Updating", 
				      $host, $newip, $prefix, $if->name);
		    $self->debug( loglevel => 'LOG_NOTICE',
				  message  => $msg );
		    unless( $ipobj = $self->updateblock(id         => $ipobj->id, 
							statusname => "Static",
							interface  => $if->id )){
			my $msg = sprintf("%s: Could not update IP %s/%s: %s", 
					  $host, $newip, $prefix, $self->error);
			$self->debug( loglevel => 'LOG_ERR',
				      message  => $msg );
			next;
		    }
		}else {
		    #
		    # Create a new Ip
		    unless( $ipobj = $self->insertblock(address    => $newip, 
							prefix     => $prefix, 
							statusname => "Static",
							interface  => $if->id)){
			my $msg = sprintf("%s: Could not insert IP %s: %s", 
					  $host, $newip, $self->error);
			$self->debug( loglevel => 'LOG_ERR',
				      message  => $msg );
			next;
		    }else{
			my $msg = sprintf("%s: Inserted IP %s", $host, $newip);
			$self->debug( loglevel => 'LOG_NOTICE',
				      message  => $msg );
			$self->output($msg);
		    }
		}
	    } # foreach newip
	} #if ips found 
    } #foreach $newif


    ########################################################
    #
    # Create A records for each ip address discovered
    #
    ########################################################
 
    my @devips = $self->getdevips($device);

    # The reason for the reverse order is that most often the lowest
    # address is a virtual address (such as when a router uses VRRP or HSRP)
    # For that virtual address, the user might want to manually assign a custom name.
    # This way, the higher address gets to keep the shorter name (without the 
    # ip address appended)
    # Otherwise, this has no adverse effects

    foreach my $ipobj ( reverse @devips ){

	# Determine what DNS name this IP will have
	my $name = $self->_canonicalize_int_name($ipobj->interface->name);
	if ( $ipobj->interface->ips > 1 
	     ||  $self->getrrbyname($name) ){
	    # Interface has more than one ip
	    # or somehow this name is already used.
	    # Append the ip address to the name to make it unique
	    $name .= "-" . $ipobj->address;
	}
	# Append device name
	# Remove any possible prefixes added
	# e.g. loopback0.devicename -> devicename
	my $suffix = $device->name->name;
	$suffix =~ s/^.*\.(.*)/$1/;
	$name .= "." . $suffix ;
	
	my @arecords = $ipobj->arecords;
	if ( ! @arecords  ){
	    
	    ################################################
	    # Is this the only ip in this device,
	    # or is this the address associated with the
	    # hostname?
	    
	    if ( (scalar @devips) == 1 || exists $hostnameips{$ipobj->address} ){
		
		# We should already have an RR created
		# Create the A record to link that RR with this ipobj
		if ( $device->name ){
		    unless ($self->insert_a_rr(rr => $device->name, 
					       ip => $ipobj)){
			my $msg = sprintf("%s: Could not insert DNS A record for %s: %s", 
					  $host, $ipobj->address, $self->error);
			$self->debug(loglevel => 'LOG_ERR',
				     message  => $msg );
			$self->output($msg);
		    }else{
			my $msg = sprintf("%s: Inserted DNS A record for %s: %s", 
					  $host, $ipobj->address, $device->name->name);
			$self->debug(loglevel => 'LOG_NOTICE',
				     message  => $msg );
			$self->output($msg);
		    }
		}
	    }else{
		# Insert necessary records
		unless ($self->insert_a_rr(name => $name,
					   ip   => $ipobj)){
		    my $msg = sprintf("%s: Could not insert DNS A record for %s: %s", 
				      $host, $ipobj->address, $self->error);
		    $self->debug(loglevel => 'LOG_ERR',
				 message  => $msg );
		    $self->output($msg);
		}else{
		    my $msg = sprintf("%s: Inserted DNS A record for %s: %s", 
				      $host, $ipobj->address, $name);
		    $self->debug(loglevel => 'LOG_NOTICE',
				 message  => $msg );
		    $self->output($msg);
		}
	    }
	}else{ 
	    # "A" records exist.  Update names
	    if ( (scalar @arecords) > 1 ){
		# There's more than one A record for this IP
		# To avoid confusion, don't update and log.
		my $msg = sprintf("%s: IP %s has more than one A record. Will not update name.", 
				  $host, $ipobj->address);
		$self->debug(loglevel => 'LOG_WARNING',
			     message  => $msg );
		$self->output($msg);
	    }else{
		my $rr = $arecords[0]->rr;
		# We won't update the RR that the device name points to
		# Also, don't bother if name hasn't changed
		if ( $rr->id != $device->name->id 
		     && $rr->name ne $name
		     && $rr->auto_update ){
		    unless ( $self->update(object => $rr, state => {name => $name} )){
			my $msg = sprintf("%s: Could not update RR %s: %s", 
					  $host, $rr->name, $self->error);
			$self->debug( loglevel => 'LOG_ERR',
				      message  => $msg,
				      );
			$self->output($msg);
		    }else{
			my $msg = sprintf("%s: Updated DNS record for %s: %s", 
					  $host, $ipobj->address, $name);
			$self->debug(loglevel => 'LOG_NOTICE',
				     message  => $msg );
			$self->output($msg);
		    }
		}
	    }
	}
    } #foreach $ipobj
    
    
    ##############################################
    #
    # remove each interface that no longer exists
    #
    ##############################################

    ## Do not remove manually-added ports for these hubs
    unless ( exists $dev{sysobjectid} 
	     && exists($self->{config}->{IGNOREPORTS}->{$dev{sysobjectid}} )){
	
	foreach my $nonif ( keys %ifs ) {
	    my $ifobj = $ifs{$nonif};

	    # Get RRs before deleting interface
	    map { push @nonrrs, $_->rr } map { $_->arecords } $ifobj->ips;
	    
	    my $msg = sprintf("%s: Interface %s,%s no longer exists.  Removing.", 
			      $host, $ifobj->number, $ifobj->name);
	    $self->debug( loglevel => 'LOG_NOTICE',
			  message  => $msg,
			  );
	    $self->output($msg);

	    ##################################################
	    # Notify of orphaned circuits
	    #
	    my @circuits;
	    map { push @circuits, $_ } $ifobj->nearcircuits;
	    map { push @circuits, $_ } $ifobj->farcircuits;

	    if ( @circuits ){
		my $msg = sprintf("%s: You might want to revise the following circuits: %s", $host, 
				  (join ', ', map { $_->cid } @circuits) );
		$self->debug( loglevel => 'LOG_NOTICE',
			      message  => $msg,
			      );
		$self->output($msg);
	    }

	    unless( $self->remove( table => "Interface", id => $nonif ) ) {
		my $msg = sprintf("%s: Could not remove Interface %s,%s: %s", 
				  $host, $ifobj->number, $ifobj->name, $self->error);
		$self->debug( loglevel => 'LOG_ERR',
			      message  => $msg,
			      );
		$self->output($msg);
		next;
	    }
	}
    }

    ##############################################
    #
    # remove each ip address that no longer exists
    #
    ##############################################
    unless ( $device->natted ){
	foreach my $nonip ( keys %dbips ) {
	    my $msg = sprintf("%s: Removing old IP %s", 
			      $host, $nonip);
	    $self->debug( loglevel => 'LOG_NOTICE',
			  message  => $msg,
			  );
	    $self->output($msg);		

	    my $ip = Ipblock->retrieve($dbips{$nonip});
	    next unless $ip;

	    # Get RRs before deleting object
	    map { push @nonrrs, $_->rr } $ip->arecords;

	    unless( $self->removeblock( id => $ip->id ) ) {
		my $msg = sprintf("%s: Could not remove IP %s: %s", 
				  $host, $nonip, $self->error);
		$self->debug( loglevel => 'LOG_ERR',
			      message  => $msg,
			      );
		$self->output($msg);
		next;
	    }
	}
    }

    ##############################################
    #
    # remove old RRs if they no longer have any
    # addresses associated
    #
    ##############################################
    
    foreach my $rr ( @nonrrs ){
	if ( (! $rr->arecords) && ($rr->id != $device->name->id) ){
	    # Assume the name can go
	    # since it has no addresses associated
	    my $msg = sprintf("%s: Removing old RR: %s", 
			      $host, $rr->name );
	    $self->debug( loglevel => 'LOG_NOTICE',
			  message  => $msg,
			  );
	    $self->output($msg);		
	    unless( $self->remove( table => "RR",  id => $rr->id ) ) {
		my $msg = sprintf("%s: Could not remove RR %s: %s", 
				  $host, $rr->name, $self->error);
		$self->debug( loglevel => 'LOG_ERR',
			      message  => $msg,
			      );
		$self->output($msg);
	    }
	}
    }

    ##############################################
    #
    # remove each vlan membership that no longer exists
    #
    ##############################################
    
    foreach my $nonvlan ( keys %dbvlans ) {
	my $iv = InterfaceVlan->retrieve($nonvlan);
	my $msg = sprintf("%s: Vlan membership %s:%s no longer exists.  Removing.", 
			  $host, $iv->interface->name, $iv->vlan->vid);
	$self->debug( loglevel => 'LOG_NOTICE',
		      message  => $msg,
		      );
	unless( $self->remove( table => 'InterfaceVlan', id => $iv->id ) ) {
	    my $msg = sprintf("%s: Could not remove InterfaceVlan %s: %s", 
			      $host, $iv->id, $self->error);
	    $self->debug( loglevel => 'LOG_ERR',
			  message  => $msg,
			  );
	    $self->output($msg);
	    next;
	}
    }

    ###############################################################
    #
    # Add/Delete BGP Peerings
    #
    ###############################################################

    if ( $self->{config}->{ADD_BGP_PEERS} ){

	################################################     
	# Keep a hash of current peerings for this Device
	#
	map { $bgppeers{ $_->id } = '' } $device->bgppeers();
	
	################################################
	# For each discovered peer
	#
	foreach my $peer ( keys %{$dev{bgppeer}} ){
	    my $p; # bgppeering object

	    # Check if peering exists
	    unless ( $p = (BGPPeering->search( device      => $device->id,
					       bgppeeraddr => $peer ))[0] ){
		# Doesn't exist.  
		# Check if we have some Entity info
		my $ent;
		if ( $dev{bgppeer}{$peer}{asnumber} ){
		    $ent = (Entity->search( asnumber => $dev{bgppeer}{$peer}{asnumber}))[0];
		    
		}elsif ( $dev{bgppeer}{$peer}{asname} ){
		    $ent = (Entity->search( asname => $dev{bgppeer}{$peer}{asname}))[0];
		    
		}elsif ( $dev{bgppeer}{$peer}{orgname} ){
		    $ent = (Entity->search( name => $dev{bgppeer}{$peer}{orgname}))[0];
		}
		
		# If we didn't find an entity
		if ( !defined($ent) && 
		     defined($dev{bgppeer}{$peer}{orgname}) &&
		     defined($dev{bgppeer}{$peer}{asname})
		     ){
		    # Doesn't exist, but we have some info. Create Entity
		    my $msg = sprintf("%s: Entity %s (%s) not found. Creating", 
				      $host, $dev{bgppeer}{$peer}{orgname}, $dev{bgppeer}{$peer}{asname});
		    $self->debug( loglevel => 'LOG_INFO',
				  message  => $msg );
		    my $t;
		    unless ( $t = (EntityType->search(name => "Peer"))[0] ){
			$t = 0; 
		    }
		    my $entname = $dev{bgppeer}{$peer}{orgname} || $dev{bgppeer}{$peer}{asname} ;
		    $entname .= "($dev{bgppeer}{$peer}{asnumber})";
		    
		    if ( my $entid = $self->insert(table => 'Entity', 
						   state => { name     => $entname,
							      asname   => $dev{bgppeer}{$peer}{asname},
							      asnumber => $dev{bgppeer}{$peer}{asnumber},
							      type => $t }) ){
			my $msg = sprintf("%s: Created Peer Entity: %s. ", $host, $entname);
			$self->debug( loglevel => 'LOG_NOTICE',
				      message  => $msg );		
			$ent = Entity->retrieve($entid);
		    }else{
			my $msg = sprintf("%s: Could not create new Entity: %s: %s", 
					  $host, $entname, $self->error);
			$self->debug( loglevel => 'LOG_ERR',
				      message  => $msg,
				      );
			$self->output($msg);
			$ent = 0;
		    }
		}
		$ent ||= 0;

		# Create Peering
		my %ptmp = (device      => $device,
			    entity      => $ent,
			    bgppeerid   => $dev{bgppeer}{$peer}{bgppeerid},
			    bgppeeraddr => $peer,
			    monitored   => 1,
			    );

		my $peername = ($ent)? $ent->name : $peer;

		if ( ($p = $self->insert(table => 'BGPPeering', 
					 state => \%ptmp ) ) ){


		    my $msg = sprintf("%s: Created Peering with: %s. ", $host, $peername);
		    $self->debug( loglevel => 'LOG_NOTICE',
				  message  => $msg );
		    $self->output($msg);
		}else{
		    my $msg = sprintf("%s: Could not create Peering with : %s: %s",
				      $host, $peername, $self->error );
		    $self->debug( loglevel => 'LOG_ERR',
				  message  => $msg,
				  );
		}
	    }else{
		# Peering Exists.  Delete from list
		delete $bgppeers{$p->id};
	    }
	}
	
	##############################################
	# remove each BGP Peering that no longer exists
	
	foreach my $nonpeer ( keys %bgppeers ) {
	    my $p = BGPPeering->retrieve($nonpeer);
	    my $msg = sprintf("%s: BGP Peering with %s (%s) no longer exists.  Removing.", 
			      $host, $p->entity->name, $p->bgppeeraddr);
	    $self->debug( loglevel => 'LOG_NOTICE',
			  message  => $msg,
			  );
	    $self->output($msg);		
	    unless( $self->remove( table => 'BGPPeering', id => $nonpeer ) ) {
		my $msg = sprintf("%s, Could not remove BGPPeering %s: %s", 
				  $host, $p->id, $self->error);
		$self->debug( loglevel => 'LOG_ERR',
			      message  => $msg,
			      );
		$self->output($msg);
		next;
	    }
	}

    } # endif ADD_BGP_PEERS
    
    # END 

    my $msg = sprintf("Discovery of %s completed", $host);
    $self->debug( loglevel => 'LOG_NOTICE',
		  message  => $msg );
    return $device;
}

=head2 get_dev_info - Get SNMP info from Device
 
 Use the SNMP libraries to get a hash with the device information
 This should hide all possible underlying SNMP code logic from our
 device insertion/update code

 Required Args:
   host:  name or ip address of host to query
   comstr: SNMP community string
 Optional args:
  

=cut

sub get_dev_info {
    my ($self, $host, $comstr) = @_;
    $self->_clear_output();

    $self->{nv}->build_config( "device", $host, $comstr );
    my (%nv, %dev);
    unless( (%nv  = $self->{nv}->get_device( "device", $host )) &&
	    exists $nv{sysUpTime} ) {
	$self->error(sprintf ("Could not reach device %s", $host) );
	$self->debug(loglevel => 'LOG_ERR',
		     message => $self->error, 
		     );
	return 0;
    }
    if ( $nv{sysUpTime} < 0 ) {
	$self->error( sprintf("Device %s did not respond", $host) );
	$self->debug( loglevel => 'LOG_ERR',
		      message => $self->error);
	return 0;
    }
    my $msg = sprintf("Contacted Device %s", $host);
    $self->debug( loglevel => 'LOG_NOTICE',
		  message  => $msg );
    
    $self->debug(loglevel => 'LOG_DEBUG',
		 message  => "Netviewer got me this: %s", 
		 args     => [ join " ", Dumper(%nv) ] );
    
    ################################################################
    # Device's global vars

    if ( $self->_is_valid($nv{sysObjectID}) ){
	$dev{sysobjectid} = $nv{sysObjectID};
	$dev{sysobjectid} =~ s/^\.(.*)/$1/;  #Remove unwanted first dot
	$dev{enterprise} = $dev{sysobjectid};
	$dev{enterprise} =~ s/(1\.3\.6\.1\.4\.1\.\d+).*/$1/;

    }
    if ( exists($self->{config}->{IGNOREDEVS}->{$dev{sysobjectid}} ) ){
	my $msg = sprintf("Product id %s is set to be ignored in config file", $dev{sysobjectid});
	$self->error($msg);
	$self->debug( loglevel => 'LOG_NOTICE', message => $msg );
	return 0;
    }

    if ( $self->_is_valid($nv{sysName}) ){
	$dev{sysname} = $nv{sysName};
    }
    if ( $self->_is_valid($nv{sysDescr}) ){
	$dev{sysdescription} = $nv{sysDescr};
    }
    if ( $self->_is_valid($nv{sysContact}) ){
	$dev{syscontact} = $nv{sysContact};
    }
    if ( $self->_is_valid($nv{sysLocation}) ){
	$dev{syslocation} = $nv{sysLocation};
    }
    ################################################################
    # Does it route?
    if ( $self->_is_valid($nv{ipForwarding}) && $nv{ipForwarding} == 1 ){
	$dev{router} = 1;
    }
    ################################################################
    # BGP?
    if ( $self->_is_valid($nv{bgpLocalAs}) ){
	$dev{bgplocalas} = $nv{bgpLocalAs};
    }
    if ( $self->_is_valid($nv{bgpIdentifier}) ){
	$dev{bgpid} = $nv{bgpIdentifier};
    }
    ################################################################
    # Is it an access point?
    if ( $self->_is_valid($nv{dot11StationID}) ){
	$dev{dot11} = 1;
    }
    # Check if base bridge address is valid
    if( $self->_is_valid($nv{dot1dBaseBridgeAddress})  ) {
	my $addr = $self->_readablehex($nv{dot1dBaseBridgeAddress});
	if ( $self->validate_phys_addr($addr) ){
	    $dev{physaddr} = $addr;
	}else{
	    my $msg = sprintf("%s is not a valid address", $addr);
	    $self->error($msg);
	    $self->debug( loglevel => 'LOG_DEBUG', message => $msg );
	}
    }
    if( $self->_is_valid($nv{entPhysicalDescr}) ) {
	$dev{productname} = $nv{entPhysicalDescr};
    }
    if( $self->_is_valid($nv{entPhysicalMfgName}) ) {
	$dev{manufacturer} = $nv{entPhysicalMfgName};
    }
    if( $self->_is_valid($nv{entPhysicalSerialNum}) ) {
	$dev{serialnumber} = $nv{entPhysicalSerialNum};
    }


    ################################################################
    # Interface status (oper/admin)

    my %IFSTATUS = ( '1' => 'up',
		     '2' => 'down' );

    ################################################################
    # MAU-MIB's ifMauType to half/full translations

    my %MAU2DUPLEX = ( '.1.3.6.1.2.1.26.4.10' => "half",
		       '.1.3.6.1.2.1.26.4.11' => "full",
		       '.1.3.6.1.2.1.26.4.12' => "half",
		       '.1.3.6.1.2.1.26.4.13' => "full",
		       '.1.3.6.1.2.1.26.4.15' => "half",
		       '.1.3.6.1.2.1.26.4.16' => "full",
		       '.1.3.6.1.2.1.26.4.17' => "half",
		       '.1.3.6.1.2.1.26.4.18' => "full",
		       '.1.3.6.1.2.1.26.4.19' => "half",
		       '.1.3.6.1.2.1.26.4.20' => "full",
		       '.1.3.6.1.2.1.26.4.21' => "half",
		       '.1.3.6.1.2.1.26.4.22' => "full",
		       '.1.3.6.1.2.1.26.4.23' => "half",
		       '.1.3.6.1.2.1.26.4.24' => "full",
		       '.1.3.6.1.2.1.26.4.25' => "half",
		       '.1.3.6.1.2.1.26.4.26' => "full",
		       '.1.3.6.1.2.1.26.4.27' => "half",
		       '.1.3.6.1.2.1.26.4.28' => "full",
		       '.1.3.6.1.2.1.26.4.29' => "half",
		       '.1.3.6.1.2.1.26.4.30' => "full",
		       );
    
    ################################################################
    # Map dot3StatsDuplexStatus

    my %DOT3DUPLEX = ( 1 => "na",
		       2 => "half",
		       3 => "full",
		       );

    ################################################################
    # Catalyst's portDuplex to half/full translations

    my %CATDUPLEX = ( 1 => "half",
		      2 => "full",
		      3 => "auto",  #(*)
		      4 => "auto",
		      );
    # (*) MIB says "disagree", but we can assume it was auto and the other 
    # end wasn't
    
    my @ifrsv = @{ $self->{config}->{'IFRESERVED'} };
    
    $self->debug( loglevel => 'LOG_DEBUG',
		  message => "Ignoring Interfaces: %s", 
		  args => [ join ', ', @ifrsv ] );	    	 
    
    ##############################################
    # Netdot to Netviewer field name translations

    my %IFFIELDS = ( number            => "instance",
		     name              => "name",
		     type              => "ifType",
		     description       => "descr",
		     speed             => "ifSpeed",
		     admin_status      => "ifAdminStatus",
		     oper_status       => "ifOperStatus" );


    ##############################################
    # for each interface discovered...
    
    foreach my $newif ( keys %{ $nv{interface} } ) {
	############################################
	# check whether should skip IF
	my $skip = 0;
	foreach my $n ( @ifrsv ) {
	    if( $nv{interface}{$newif}{name} =~ /$n/ ) { $skip = 1; last }
	}
	next if( $skip );

	foreach my $dbname ( keys %IFFIELDS ) {
	    if( $dbname =~ /status/ ) {
		my $val = $nv{interface}{$newif}{$IFFIELDS{$dbname}};
		if( $val =~ /\d+/ ){
		    $dev{interface}{$newif}{$dbname} = $IFSTATUS{$val};
		}else{
		    # Netviewer changes it in some cases.
		    # Just use the value
		    $dev{interface}{$newif}{$dbname} = $val;	    
		}
	    }elsif( $dbname eq "description" ){
		# Netviewer converts empty values into "-"
		# Ignore those
		next if ( $nv{interface}{$newif}{$IFFIELDS{$dbname}} eq "-" );
		$dev{interface}{$newif}{$dbname} = $nv{interface}{$newif}{$IFFIELDS{$dbname}};
	    }else {
		$dev{interface}{$newif}{$dbname} = $nv{interface}{$newif}{$IFFIELDS{$dbname}};
	    }
	}
	if ( $self->_is_valid($nv{interface}{$newif}{ifPhysAddress}) ){
	    my $addr = $self->_readablehex($nv{interface}{$newif}{ifPhysAddress});
	    if ( $self->validate_phys_addr($addr) ){
		$dev{interface}{$newif}{physaddr} = $addr;
	    }else{
		my $msg = sprintf("%s is not a valid address", $addr);
		$self->error($msg);
		$self->debug( loglevel => 'LOG_DEBUG', message => $msg );
	    }
	}	
	################################################################
	# Set Oper Duplex mode
	my ($opdupval, $opdup);
	################################################################
	if( $self->_is_valid($nv{interface}{$newif}{ifMauType}) ){
	    ################################################################
	    # ifMauType
	    $opdupval = $nv{interface}{$newif}{ifMauType};
	    $opdup = $MAU2DUPLEX{$opdupval} || "";

	}
	if( $self->_is_valid($nv{interface}{$newif}{ifSpecific}) && !($opdup) ){
	    ################################################################
	    # ifSpecific
	    $opdupval = $nv{interface}{$newif}{ifSpecific};
	    $opdup = $MAU2DUPLEX{$opdupval} || "";

	}
	if( $self->_is_valid($nv{interface}{$newif}{dot3StatsDuplexStatus}) && !($opdup) ){
	    ################################################################
	    # dot3Stats
	    $opdupval = $nv{interface}{$newif}{dot3StatsDuplexStatus};
	    $opdup = $DOT3DUPLEX{$opdupval} || "";

	}
	if( $self->_is_valid($nv{interface}{$newif}{portDuplex}) && !($opdup) ){
	    ################################################################
	    # Catalyst
	    $opdupval = $nv{interface}{$newif}{portDuplex};
	    $opdup = $CATDUPLEX{$opdupval} || "";
	}
	$dev{interface}{$newif}{oper_duplex} = $opdup || "na" ;  	    

	################################################################
	# Set Admin Duplex mode
	my ($admindupval, $admindup);
	################################################################
	# Standard MIB
	if ($self->_is_valid($nv{interface}{$newif}{ifMauDefaultType})){
	    $admindupval = $nv{interface}{$newif}{ifMauDefaultType};
	    $admindup= $MAU2DUPLEX{$admindupval} || 0;
	}
	$dev{interface}{$newif}{admin_duplex} = $admindup || "na";

	####################################################################
	# IP addresses and masks 
	# (mask is the value for each ip address key)
	foreach my $ip( keys %{ $nv{interface}{$newif}{ipAdEntIfIndex}}){
	    $dev{interface}{$newif}{ips}{$ip} = $nv{interface}{$newif}{ipAdEntIfIndex}{$ip};
	}

	################################################################
	# Vlan info
	my ($vid, $vname);
	################################################################
	# Standard MIB
	if( $self->_is_valid( $nv{interface}{$newif}{dot1qPvid} ) ) {
	    $vid = $nv{interface}{$newif}{dot1qPvid};
	    $vname = ( $self->_is_valid($nv{interface}{$newif}{dot1qVlanStaticName}) ) ? 
		$nv{interface}{$newif}{dot1qVlanStaticName} : $vid;
	    $dev{interface}{$newif}{vlans}{$vid} = $vname;
	    ################################################################
	    # HP
	}elsif( $self->_is_valid( $nv{interface}{$newif}{hpVlanMemberIndex} ) ){
	    $vid = $nv{interface}{$newif}{hpVlanMemberIndex};
	    $vname = ( $self->_is_valid($nv{interface}{$newif}{hpVlanIdentName}) ) ?
		$nv{interface}{$newif}{hpVlanIdentName} : $vid;
	    $dev{interface}{$newif}{vlans}{$vid} = $vname;
	    ################################################################
	    # Cisco
	}elsif( $self->_is_valid( $nv{interface}{$newif}{vmVlan} )){
	    $vid = $nv{interface}{$newif}{vmVlan};
	    $vname = ( $self->_is_valid($nv{cviRoutedVlan}{$vid.0}{name}) ) ? 
		$nv{cviRoutedVlan}{$vid.0}{name} : $vid;
	    $dev{interface}{$newif}{vlans}{$vid} = $vname;
	}

    }
    ##############################################
    # for each hubport discovered...
    if ( scalar ( my @hubports = keys %{ $nv{hubPorts} } ) ){
	$dev{hub} = 1;
	if ( ! exists($self->{config}->{IGNOREPORTS}->{$dev{sysobjectid}}) ){
	    foreach my $newport ( @hubports ) {
		$dev{interface}{$newport}{name}         = $newport;
		$dev{interface}{$newport}{number}       = $newport;
		$dev{interface}{$newport}{speed}        = "10 Mbps"; #most likely
		$dev{interface}{$newport}{oper_duplex}  = "na";
		$dev{interface}{$newport}{admin_duplex} = "na";
		$dev{interface}{$newport}{oper_status}  = "na";
		$dev{interface}{$newport}{admin_status} = "na";
	    }
	}
    }
    
    if ( $self->{config}->{ADD_BGP_PEERS} ){
	##############################################
	# for each BGP Peer discovered...
	
	foreach my $peer ( keys %{ $nv{bgpPeer} } ) {
	    my $peerid = $nv{bgpPeer}{$peer}{bgpPeerIdentifier};
	    unless ( defined $peerid ){
		$self->debug( loglevel => 'LOG_DEBUG', 
			      message  => "Did not get bgpPeerIdentifier for peer %s",
			      args     => [$peer]);
		$peerid = "0.0.0.0";
	    }
	    
	    $dev{bgppeer}{$peer}{bgppeerid} = $peerid;

	    my $asn = $nv{bgpPeer}{$peer}{bgpPeerRemoteAs};
	    if ( defined $asn ){
		$dev{bgppeer}{$peer}{asnumber} = $asn;
		
		# Query any configured WHOIS servers for more info
		#
		if ( $self->{config}->{DO_WHOISQ} ){
		    my $found = 0;
		    foreach my $host ( keys %{$self->{config}->{WHOISQ}} ){
			my @lines = `whois -h $host AS$asn`;
			unless ( grep /No.*found/i, @lines ){
			    foreach my $key ( keys %{$self->{config}->{WHOISQ}->{$host}} ){
				my $exp = $self->{config}->{WHOISQ}->{$host}->{$key};
				if ( my @l = grep /^$exp/, @lines ){
				    my (undef, $val) = split /:\s+/, $l[0]; #first line
				    chomp($val);
				    $dev{bgppeer}{$peer}{$key} = $val;
				    $found = 1;
				}
			    }
			}
			last if $found;
		    }
		    unless ( $found ){
			$dev{bgppeer}{$peer}{asname}  = "AS $asn";
			$dev{bgppeer}{$peer}{orgname} = "AS $asn";		    
		    }
		}else{
		    $dev{bgppeer}{$peer}{asname}  = "AS $asn";
		    $dev{bgppeer}{$peer}{orgname} = "AS $asn";
		}
	    }else{
		$self->debug( loglevel => 'LOG_DEBUG', 
			      message  => "Did not get bgpPeerRemoteAs for peer %s",
			      args     => [$peer]);
	    }
	}
    }
    
    return \%dev;
}

=head2 getdevips  - Get all IP addresses configured in a device
   
  Arguments:
    id of the device
    sort field
  Returns:
    array of Ipblock objects

=cut

sub getdevips {
    my ($self, $id, $ipsort) = @_;
    my @ips;
    $ipsort ||= "address";
    if ( $ipsort eq "address" ){
	if ( @ips = Ipblock->search_devipsbyaddr( $id ) ){
	    return @ips;
	}
    }elsif ( $ipsort eq "interface" ){
	if ( @ips = Ipblock->search_devipsbyint( $id ) ){
	    return @ips;
	}
    }else{
	$self->error("invalid sort criteria: $ipsort");
	return;
    }
    return;
}

=head2 getdevsubnets  - Get all the subnets in which a given device has any addresses
   
  Arguments:
    id of the device
  Returns:
    hash of Ipblock objects, keyed by id

=cut

sub getdevsubnets {
    my ($self, $id) = @_;
    my %subnets;
    foreach my $ip ( $self->getdevips($id) ){
	my $subnet;
	if ( ($subnet = $ip->parent) && 
	     $subnet->status->name eq "Subnet"){
	    $subnets{$subnet->id} = $subnet;
	}
    }
    return %subnets;
}

=head2 getproductsbytype  - Get all products of given type
   
  Arguments:
    id of ProductType
    if id is 0, return products with no type set
  Returns:
    array of Product objects

=cut

sub getproductsbytype {
    my ($self, $id) = @_;
    my @objs;
    if ( $id ){
	if ( @objs = Product->search_bytype( $id ) ){
	    return @objs;
	}
    }else{
	if ( @objs = Product->search_notype() ){
	    return @objs;
	}
    }
    return;
}

=head2 getdevsbytype  - Get all devices of given type
   
  Arguments:
    id of ProductType
    if id is 0, return products with no type set
  Returns:
    array of Device objects

=cut

sub getdevsbytype {
    my ($self, $id) = @_;
    my @objs;
    if ( $id ){
	if ( @objs = Device->search_bytype( $id ) ){
	    return @objs;
	}
    }
    return;
}

=head2 add_interfaces - Manually add a number of interfaces to an existing device

The new interfaces will be added with numbers starting after the highest existing 
interface number

Arguments:
    Device id
    Number of interfaces
Returns:
    True or False

=cut

sub add_interfaces {
    my ($self, $id, $num) = @_;
    unless ( $num > 0 ){
	$self->error("Invalid number of Interfaces to add: $num");
	return 0;
    }
    # Determine highest numbered interface in this device
    my $device;
    unless ( $device =  Device->retrieve($id) ){
	$self->error("add_interfaces: Could not retrieve Device id $id");
    }
    my @ints;
    my $start;
    if ( scalar ( @ints = sort { $b->number <=> $a->number } $device->interfaces ) ){
	$start = int ( $ints[0]->number );
    }else{
	$start = 0;
    }
    my %tmp = ( device => $id, number => $start);
    my $i;
    for ($i = 0; $i < $num; $i++){
	$tmp{number}++;
	if (!($self->insert(table => "Interface", state => \%tmp)) ){
	    $self->error(sprintf("add_interfaces: %s", $self->error));
	    return 0;
	}
    }
    return 1;
}

=head2 ints_by_number - Retrieve interfaces from a Device and sort by number.  
                              Handles the case of port numbers with dots (hubs)

Arguments:  Device object
Returns:    Sorted array of interface objects or undef if error.

=cut

sub ints_by_number {
    my ( $self, $o ) = @_;
    my @ifs;
    unless ( @ifs = $o->interfaces() ){
	return ;
    }
    # Add a fake '.0' after numbers with no dots, and then
    # split in two and sort first part and then second part
    # (i.e: 1.10 goes after 1.2)
    my @tmp;
    foreach my $if ( @ifs ) {
	my $num = $if->number;
	if ($num !~ /\./ ){
	    $num .= '.0';
	}
	push @tmp, [(split /\./, $num), $if];
    }	
    @ifs = map { $_->[2] } sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @tmp;

    return unless scalar @ifs;
    return @ifs;
}

=head2 ints_by_name - Retrieve interfaces from a Device and sort by name.  

This method deals with the problem of sorting Interface names that contain numbers.
Simple alphabetical sorting does not yield useful results.

Arguments:  Device object
Returns:    Sorted array of interface objects or undef if error.

=cut

sub ints_by_name {
    my ( $self, $o ) = @_;
    my @ifs;
    my @ifs = $o->interfaces;
    
    # The following was borrowed from Netviewer
    # and was slightly modified to handle Netdot Interface objects.
    @ifs = ( map { $_->[0] } sort { 
	       $a->[1] cmp $b->[1]
	    || $a->[2] <=> $b->[2]
	    || $a->[3] <=> $b->[3]
	    || $a->[4] <=> $b->[4]
	    || $a->[5] <=> $b->[5]
	    || $a->[6] <=> $b->[6]
	    || $a->[7] <=> $b->[7]
	    || $a->[8] <=> $b->[8]
	    || $a->[0]->name cmp $b->[0]->name }  
	     map{ [ $_, $_->name =~ /^([^\d]+)\d/, 
		    ( split( /[^\d]+/, $_->name ))[0,1,2,3,4,5,6,7,8] ] } @ifs);
    
    return unless scalar @ifs;
    return @ifs;

}

=head2 ints_by_speed - Retrieve interfaces from a Device and sort by speed.  

Arguments:  Device object
Returns:    Sorted array of interface objects or undef if error.

=cut

sub ints_by_speed {
    my ( $self, $o ) = @_;
    my $id = $o->id;
    my @ifs = Interface->search( device => $id, {order_by => 'speed'});

    return unless scalar @ifs;
    return @ifs;
}

=head2 interfaces_by_vlan - Retrieve interfaces from a Device and sort by vlan ID

Arguments:  Device object
Returns:    Sorted array of interface objects or undef if error.

Note: If the interface has/belongs to more than one vlan, sort function will only
use one of the values.

=cut

sub ints_by_vlan {
    my ( $self, $o ) = @_;
    my @ifs;
    unless ( @ifs = $o->interfaces() ){
	return ;
    }
    my @tmp = map { [ ($_->vlans) ? ($_->vlans)[0]->vlan->vid : 0, $_] } @ifs;
	
    @ifs = map { $_->[1] } sort { $a->[0] <=> $b->[0] } @tmp;

    return unless scalar @ifs;
    return @ifs;
}

sub ints_by_jack {
    my ( $self, $o ) = @_;
    my @ifs;
    unless ( @ifs = $o->interfaces() ){
	return ;
    }
    my @tmp = map { [ ($_->jack) ? $_->jack->jackid : 0, $_] } @ifs;
	
    @ifs = map { $_->[1] } sort { $a->[0] cmp $b->[0] } @tmp;

    return unless scalar @ifs;
    return @ifs;
}

=head2 interfaces_by_descr - Retrieve interfaces from a Device and sort by description

Arguments:  Device object
Returns:    Sorted array of interface objects or undef if error.

=cut

sub ints_by_descr {
    my ( $self, $o ) = @_;
    my $id = $o->id;
    my @ifs = Interface->search( device => $id, {order_by => 'description'});

    return unless scalar @ifs;
    return @ifs;
}

=head2 interfaces_by_monitored - Retrieve interfaces from a Device and sort by 'monitored' field

Arguments:  Device object
Returns:    Sorted array of interface objects or undef if error.

=cut

sub ints_by_monitored {
    my ( $self, $o ) = @_;
    my $id = $o->id;
    my @ifs = Interface->search( device => $id, {order_by => 'monitored DESC'});

    return unless scalar @ifs;
    return @ifs;
}

=head2 interfaces_by_snmp - Retrieve interfaces from a Device and sort by 'snmp_managed' field

Arguments:  Device object
Returns:    Sorted array of interface objects or undef if error.

=cut

sub ints_by_snmp {
    my ( $self, $o ) = @_;
    my $id = $o->id;
    my @ifs = Interface->search( device => $id, {order_by => 'snmp_managed DESC'});

    return unless scalar @ifs;
    return @ifs;
}

=head2 interfaces_by_jack - Retrieve interfaces from a Device and sort by Jack id

Arguments:  Device object
Returns:    Sorted array of interface objects or undef if error.

=cut

=head2 get_interfaces - Wrapper function to retrieve interfaces from a Device

Will call different methods depending on the sort field specified

Arguments:  Device object, sort field: [number|name|speed|vlan|jack|descr|monitored|snmp]
Returns:    Sorted array of interface objects or undef if error.

=cut

sub get_interfaces {
    my ( $self, $o, $sortby ) = @_;
    unless ( ref($o) eq "Device" ){
	self->error("get_interfaces: First parameter must be a Device object");
	return;
    }
    my @ifs;

    if ( $sortby eq "number" ){
	@ifs = $self->ints_by_number($o);
    }elsif ( $sortby eq "name" ){
	@ifs = $self->ints_by_name($o);
    }elsif( $sortby eq "speed" ){
	@ifs = $self->ints_by_speed($o);
    }elsif( $sortby eq "vlan" ){
	@ifs = $self->ints_by_vlan($o);
    }elsif( $sortby eq "jack" ){
	@ifs = $self->ints_by_jack($o);
    }elsif( $sortby eq "descr"){
	@ifs = $self->ints_by_descr($o);
    }elsif( $sortby eq "monitored"){
	@ifs = $self->ints_by_monitored($o);
    }elsif( $sortby eq "snmp"){
	@ifs = $self->ints_by_snmp($o);
    }else{
	$self->error("get_interfaces: Unknown sort field: $sortby");
	return;
    }

    return unless scalar @ifs;
    return @ifs;
}

=head2 bgppeers_by_ip - Sort by remote IP

Arguments:  Array ref of BGPPeering objects
Returns:    Sorted array of BGPPeering objects or undef if error.

=cut

sub bgppeers_by_ip {
    my ( $self, $peers ) = @_;

    my @peers = map { $_->[1] } 
    sort ( { pack("C4"=>$a->[0] =~ /(\d+)\.(\d+)\.(\d+)\.(\d+)/) 
		 cmp pack("C4"=>$b->[0] =~ /(\d+)\.(\d+)\.(\d+)\.(\d+)/); }  
	   map { [$_->bgppeeraddr, $_] } @$peers );
 
    wantarray ? ( @peers ) : $peers[0]; 
}

=head2 bgppeers_by_id - Sort by BGP ID

Arguments:  Array ref of BGPPeering objects
Returns:    Sorted array of BGPPeering objects or undef if error.

=cut

sub bgppeers_by_id {
    my ( $self, $peers ) = @_;

    my @peers = map { $_->[1] } 
    sort ( { pack("C4"=>$a->[0] =~ /(\d+)\.(\d+)\.(\d+)\.(\d+)/) 
		 cmp pack("C4"=>$b->[0] =~ /(\d+)\.(\d+)\.(\d+)\.(\d+)/); }  
	   map { [$_->bgppeerid, $_] } @$peers );
    
    wantarray ? ( @peers ) : $peers[0]; 
}

=head2 bgppeers_by_entity - Sort by Entity name, AS number or AS Name

Arguments:  
    Array ref of BGPPeering objects, 
    Entity table field to sort by [name|asnumber|asname]
Returns:    Sorted array of BGPPeering objects or undef if error.

=cut

sub bgppeers_by_entity {
    my ( $self, $peers, $sort ) = @_;
    $sort ||= "name";
    unless ( $sort =~ /name|asnumber|asname/ ){
	$self->error("Invalid Entity field: $sort");
	return;
    }
    my $sortsub = ($sort eq "asnumber") ? sub{$a->entity->$sort <=> $b->entity->$sort} : sub{$a->entity->$sort cmp $b->entity->$sort};
    my @peers = sort $sortsub @$peers;
    
    wantarray ? ( @peers ) : $peers[0]; 

}


=head2 get_bgp_peers - Retrieve BGP peers that match certain criteria and sort them

    my @localpeers = $dm->get_bgpeers(device=>$o, type=>1, sort=>"name");

Arguments:  (Hash ref)
  device:   Device object (required)
  entity:   Return peers whose entity name matches 'entity'
  id:       Return peers whose ID matches 'id'
  ip:       Return peers whose Remote IP  matches 'ip'
  as:       Return peers whose AS matches 'as'
  type      Return peers of type [internal|external|all]
  sort:     [entity|asnumber|asname|id|ip]
  
Returns:    Sorted array of BGPPeering objects, undef if none found or if error.

=cut

sub get_bgp_peers {
    my ( $self, %args ) = @_;
    unless ( $args{device} || ref($args{device}) ne "Device" ){
	$self->error("get_bgp_peers: Device object required");
	return;
    }
    my $o = $args{device};
    $args{type} ||= "all";
    $args{sort} ||= "entity";
    my @peers;
    if ( $args{entity} ){
	@peers = grep { $_->entity->name eq $args{entity} } $o->bgppeers;
    }elsif ( $args{id} ){
	@peers = grep { $_->bgppeerid eq $args{id} } $o->bgppeers;	
    }elsif ( $args{ip} ){
	@peers = grep { $_->bgppeeraddr eq $args{id} } $o->bgppeers;	
    }elsif ( $args{as} ){
	@peers = grep { $_->asnumber eq $args{as} } $o->bgppeers;	
    }elsif ( $args{type} ){
	if ( $args{type} eq "internal" ){
	    @peers = grep { $_->entity->asnumber == $o->bgplocalas } $o->bgppeers;
	}elsif ( $args{type} eq "external" ){
	    @peers = grep { $_->entity->asnumber != $o->bgplocalas } $o->bgppeers;
	}elsif ( $args{type} eq "all" ){
	    @peers = $o->bgppeers;
	}else{
	    $self->error("get_bgp_peers: Invalid type: $args{type}");
	    return;
	}
    }elsif ( ! $args{sort} ){
	$self->error("get_bgp_peers: Missing or invalid search criteria");
	return;
    }
    if ( $args{sort} =~ /entity|asnumber|asname/ ){
	$args{sort} =~ s/entity/name/;
	return $self->bgppeers_by_entity(\@peers, $args{sort});
    }elsif( $args{sort} eq "ip" ){
	return $self->bgppeers_by_ip(\@peers);
    }elsif( $args{sort} eq "id" ){
	return $self->bgppeers_by_id(\@peers);
    }else{
	$self->error("get_bgp_peers: Invalid sort argument: $args{sort}");
	return;
    }
}


=head2 convert_ifspeed - Convert ifSpeed to something more readable


Arguments:  ifSpeed value (integer)
Returns:    Human readable speed string or n/a

=cut

sub convert_ifspeed {
    my ($self, $speed) = @_;
    
    my %SPEED_MAP = ('56000'       => '56 kbps',
		     '64000'       => '64 kbps',
		     '1500000'     => '1.5 Mbps',
		     '1536000'     => 'T1',      
		     '1544000'     => 'T1',
		     '2000000'     => '2.0 Mbps',
		     '2048000'     => '2.048 Mbps',
		     '3072000'     => 'Dual T1',
		     '3088000'     => 'Dual T1',   
		     '4000000'     => '4.0 Mbps',
		     '10000000'    => '10 Mbps',
		     '11000000'    => '11 Mbps',
		     '20000000'    => '20 Mbps',
		     '16000000'    => '16 Mbps',
		     '16777216'    => '16 Mbps',
		     '44210000'    => 'T3',
		     '44736000'    => 'T3',
		     '45000000'    => '45 Mbps',
		     '45045000'    => 'DS3',
		     '46359642'    => 'DS3',
		     '54000000'    => '54 Mbps',
		     '64000000'    => '64 Mbps',
		     '100000000'   => '100 Mbps',
		     '149760000'   => 'ATM on OC-3',
		     '155000000'   => 'OC-3',
		     '155519000'   => 'OC-3',
		     '155520000'   => 'OC-3',
		     '400000000'   => '400 Mbps',
		     '599040000'   => 'ATM on OC-12', 
		     '622000000'   => 'OC-12',
		     '622080000'   => 'OC-12',
		     '1000000000'  => '1 Gbps',
		     '10000000000' => '10 Gbps',
		     );
    if ( exists $SPEED_MAP{$speed} ){
	return $SPEED_MAP{$speed};
    }else{
	return "n/a";
    }
}

#####################################################################
# Private methods
#####################################################################

#####################################################################
# Compare Quad IP addresses
# 
# Assumes ddd.ddd.ddd.ddd format. "borrowed" from
# http://www.sysarch.com/perl/sort_paper.html
#####################################################################
#sub _compare_ip($self){
#    pack("C4"=>$a =~ /(\d+)\.(\d+)\.(\d+)\.(\d+)/) cmp pack("C4"=>$b =~ /(\d+)\.(\d+)\.(\d+)\.(\d+)/);
#}

#####################################################################
# _is_valid
# 
# Returns:
#   true if valid, false otherwise
#####################################################################
sub _is_valid {
    my ($self, $v) = @_;
    
    if ( defined($v) && (length($v) > 0) && ($v !~ /nosuch|unknown/i) ){
	return 1;
    }
    return 0;
}

#####################################################################
# Clear output buffer
#####################################################################
sub _clear_output {
    my $self = shift;
    $self->{'_output'} = undef;
}

#####################################################################
# Convert hex values returned from SNMP into a readable string
#####################################################################
sub _readablehex {
    my ($self, $v) = @_;
    return uc( sprintf('%s', unpack('H*', $v)) );
}

#####################################################################
# Canonicalize Interface Name (for DNS)
#####################################################################
sub _canonicalize_int_name {
    my ($self, $name) = @_;

    my %ABBR = % {$self->{config}->{IF_DNS_ABBR} };
    foreach my $ab (keys %ABBR){
	$name =~ s/^$ab/$ABBR{$ab}/i;
    }
    $name =~ s/\/|\.|\s+/-/g;
    return lc( $name );
}