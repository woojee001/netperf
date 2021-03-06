package perfSONAR_PS::Services::MA::SNMP;

use base 'perfSONAR_PS::Services::Base';

use fields 'LS_CLIENT', 'NAMESPACES', 'METADATADB', 'LOGGER', 'NETLOGGER', 'HASH_TO_ID', 'ID_TO_HASH', 'STORE_FILE_MTIME', 'BAD_MTIME';

use strict;
use warnings;

our $VERSION = 3.3;

=head1 NAME

perfSONAR_PS::Services::MA::SNMP - A module that provides methods for the 
perfSONAR-PS SNMP based Measurement Archive (MA).

=head1 DESCRIPTION

This module, in conjunction with other parts of the perfSONAR-PS framework,
handles specific messages from interested actors in search of SNMP data.  There
are three major message types that this service can act upon:

 - MetadataKeyRequest     - Given some metadata about a specific measurement, 
                            request a re-playable 'key' to faster access
                            underlying data.
 - SetupDataRequest       - Given either metadata or a key regarding a specific
                            measurement, retrieve data values.
 - MetadataStorageRequest - Store data into the archive (unsupported)
 
The module is capable of dealing with several characteristic and tool based
eventTypes related to the underlying data as well as the aforementioned message
types.  

=cut

use Log::Log4perl qw(get_logger);
use Module::Load;
use Digest::MD5 qw(md5_hex);
use English qw( -no_match_vars );
use Params::Validate qw(:all);
use Date::Manip;
use File::Copy;

use perfSONAR_PS::Services::MA::General;
use perfSONAR_PS::Common;
use perfSONAR_PS::Messages;
use perfSONAR_PS::Client::LS::Remote;
use perfSONAR_PS::Error_compat qw/:try/;
use perfSONAR_PS::DB::File;
use perfSONAR_PS::DB::RRD;
use perfSONAR_PS::DB::SQL;
use perfSONAR_PS::DB::ESxSNMP;
use perfSONAR_PS::Utils::ParameterValidation;
use perfSONAR_PS::Utils::NetLogger;

my %ma_namespaces = (
    nmwg      => "http://ggf.org/ns/nmwg/base/2.0/",
    nmtm      => "http://ggf.org/ns/nmwg/time/2.0/",
    snmp      => "http://ggf.org/ns/nmwg/tools/snmp/2.0/",
    netutil   => "http://ggf.org/ns/nmwg/characteristic/utilization/2.0/",
    neterr    => "http://ggf.org/ns/nmwg/characteristic/errors/2.0/",
    netdisc   => "http://ggf.org/ns/nmwg/characteristic/discards/2.0/",
    select    => "http://ggf.org/ns/nmwg/ops/select/2.0/",
    average   => "http://ggf.org/ns/nmwg/ops/average/2.0/",
    perfsonar => "http://ggf.org/ns/nmwg/tools/org/perfsonar/1.0/",
    psservice => "http://ggf.org/ns/nmwg/tools/org/perfsonar/service/1.0/",
    nmwgt     => "http://ggf.org/ns/nmwg/topology/2.0/",
    nmwgtopo3 => "http://ggf.org/ns/nmwg/topology/base/3.0/",
    nmwgt3    => "http://ggf.org/ns/nmwg/topology/base/3.0/",
    nmtb      => "http://ogf.org/schema/network/topology/base/20070828/",
    nmtl2     => "http://ogf.org/schema/network/topology/l2/20070828/",
    nmtl3     => "http://ogf.org/schema/network/topology/l3/20070828/",
    nmtl4     => "http://ogf.org/schema/network/topology/l4/20070828/",
    nmtopo    => "http://ogf.org/schema/network/topology/base/20070828/",
    nmtb      => "http://ogf.org/schema/network/topology/base/20070828/",
    nmwgr     => "http://ggf.org/ns/nmwg/result/2.0/",
    ganglia   => "http://ggf.org/ns/nmwg/tools/ganglia/2.0/"
);

=head1 API

The offered API is not meant for external use as many of the functions are
relied upon by internal aspects of the perfSONAR-PS framework.

=head2 init($self, $handler)

Called at startup by the daemon when this particular module is loaded into
the perfSONAR-PS deployment.  Checks the configuration file for the necessary
items and fills in others when needed. Initializes the backed metadata storage
(sqlite or a simple XML file) and builds the internal 'key hash' for the 
MetadataKey exchanges.  Finally the message handler loads the appropriate 
message types and eventTypes for this module.  Any other 'pre-startup' tasks
should be placed in this function.

Due to performance issues, the database access must be handled in two different
ways:

 - File Database - it is expensive to continuously open the file and store it as
                   a DOM for each access.  Therefore it is opened once by the
                   daemon and used by each connection.  A $self object can
                   be used for this.

=cut

sub init {
    my ( $self, $handler ) = @_;
    $self->{LOGGER}    = get_logger( "perfSONAR_PS::Services::MA::SNMP" );
    $self->{NETLOGGER} = get_logger( "NetLogger" );

    unless ( exists $self->{CONF}->{"root_hints_url"} ) {
        $self->{CONF}->{"root_hints_url"} = q{};
        $self->{LOGGER}->info( "gLS Hints file was not set, automatic discovery of hLS instance disabled." );
    }

    if ( exists $self->{CONF}->{"root_hints_file"} and $self->{CONF}->{"root_hints_file"} ) {
        unless ( $self->{CONF}->{"root_hints_file"} =~ "^/" ) {
            $self->{CONF}->{"root_hints_file"} = $self->{DIRECTORY} . "/" . $self->{CONF}->{"root_hints_file"};
            $self->{LOGGER}->debug( "Setting full path to 'root_hints_file': \"" . $self->{CONF}->{"root_hints_file"} . "\"" );
        }
    }
    else {
        $self->{CONF}->{"root_hints_file"} = $self->{DIRECTORY} . "/gls.root.hints";
        $self->{LOGGER}->info( "Setting 'root_hints_file': \"" . $self->{CONF}->{"root_hints_file"} . "\"" );
    }

    unless ( exists $self->{CONF}->{"snmp"}->{"metadata_db_type"}
        and $self->{CONF}->{"snmp"}->{"metadata_db_type"} )
    {
        $self->{LOGGER}->fatal( "Value for 'metadata_db_type' is not set." );
        return -1;
    }

    if ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "file" ) {
        if ( exists $self->{CONF}->{"snmp"}->{"metadata_db_file"} and $self->{CONF}->{"snmp"}->{"metadata_db_file"} ) {
            if ( exists $self->{DIRECTORY} and $self->{DIRECTORY} and -d $self->{DIRECTORY} ) {
                unless ( $self->{CONF}->{"snmp"}->{"metadata_db_file"} =~ "^/" ) {
                    $self->{CONF}->{"snmp"}->{"metadata_db_file"} = $self->{DIRECTORY} . "/" . $self->{CONF}->{"snmp"}->{"metadata_db_file"};
                    $self->{LOGGER}->info( "Setting \"metadata_db_file\" to \"" . $self->{DIRECTORY} . "/" . $self->{CONF}->{"snmp"}->{"metadata_db_file"} . "\"" );
                }
            }
        }
        else {
            $self->{LOGGER}->fatal( "Value for 'metadata_db_file' is not set." );
            return -1;
        }
    }
    elsif ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "xmldb" ) {
        $self->{LOGGER}->fatal( "'metadata_db_type' of type xmldb no longer supported. Please change to 'file' or 'sqlite'" );
        return -1;
    }
    elsif ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "sqlite" ) {
        unless ( exists $self->{CONF}->{"snmp"}->{"metadata_db_file"}
            and $self->{CONF}->{"snmp"}->{"metadata_db_file"} )
        {
            $self->{LOGGER}->warn( "Value for 'metadata_db_file' is not set, setting to 'snmpstore.db'." );
            $self->{CONF}->{"snmp"}->{"metadata_db_file"} = "snmpstore.db";
        }
    }
    else {
        $self->{LOGGER}->fatal( "Wrong value for 'metadata_db_type' set." );
        return -1;
    }

    unless ( exists $self->{CONF}->{"snmp"}->{"rrdtool"}
        and $self->{CONF}->{"snmp"}->{"rrdtool"} )
    {
        $self->{LOGGER}->fatal( "Value for 'rrdtool' is not set." );
        return -1;
    }

    unless ( exists $self->{CONF}->{"snmp"}->{"default_resolution"}
        and $self->{CONF}->{"snmp"}->{"default_resolution"} )
    {
        $self->{CONF}->{"snmp"}->{"default_resolution"} = "300";
        $self->{LOGGER}->warn( "Setting 'default_resolution' to '300'." );
    }

    unless ( exists $self->{CONF}->{"snmp"}->{enable_registration} ) {
        if ( exists $self->{CONF}->{enable_registration} and $self->{CONF}->{enable_registration} ) {
            $self->{CONF}->{"snmp"}->{enable_registration} = $self->{CONF}->{enable_registration};
        }
        else {
            $self->{CONF}->{enable_registration} = 0;
            $self->{CONF}->{"snmp"}->{enable_registration} = 0;
        }
        $self->{LOGGER}->warn( "Setting 'enable_registration' to \"" . $self->{CONF}->{"snmp"}->{enable_registration} . "\"." );
    }

    if ( $self->{CONF}->{"snmp"}->{"enable_registration"} ) {
        unless ( exists $self->{CONF}->{"snmp"}->{"ls_instance"}
            and $self->{CONF}->{"snmp"}->{"ls_instance"} )
        {
            if ( defined $self->{CONF}->{"ls_instance"}
                and $self->{CONF}->{"ls_instance"} )
            {
                $self->{LOGGER}->warn( "Setting \"ls_instance\" to \"" . $self->{CONF}->{"ls_instance"} . "\"" );
                $self->{CONF}->{"snmp"}->{"ls_instance"} = $self->{CONF}->{"ls_instance"};
            }
            else {
                $self->{LOGGER}->warn( "No LS instance specified for SNMP service" );
            }
        }

        unless ( exists $self->{CONF}->{"snmp"}->{"ls_registration_number"}
            and $self->{CONF}->{"snmp"}->{"ls_registration_number"} )
        {
            $self->{LOGGER}->warn( "Setting registration number to 2 hosts (e.g. will not register to anymore than 2 LS instances) " );
            $self->{CONF}->{"snmp"}->{"ls_registration_number"} = 2;
        }

        unless ( exists $self->{CONF}->{"snmp"}->{"ls_registration_interval"}
            and $self->{CONF}->{"snmp"}->{"ls_registration_interval"} )
        {
            if ( defined $self->{CONF}->{"ls_registration_interval"}
                and $self->{CONF}->{"ls_registration_interval"} )
            {
                $self->{LOGGER}->warn( "Setting \"ls_registration_interval\" to \"" . $self->{CONF}->{"ls_registration_interval"} . "\"" );
                $self->{CONF}->{"snmp"}->{"ls_registration_interval"} = $self->{CONF}->{"ls_registration_interval"};
            }
            else {
                $self->{LOGGER}->warn( "Setting registration interval to 4 hours" );
                $self->{CONF}->{"snmp"}->{"ls_registration_interval"} = 14400;
            }
        }

        if ( not $self->{CONF}->{"snmp"}->{"service_accesspoint"} ) {
            unless ( $self->{CONF}->{external_address} ) {
                $self->{LOGGER}->fatal( "With LS registration enabled, you need to specify either the service accessPoint for the service or the external_address" );
                return -1;
            }
            $self->{LOGGER}->info( "Setting service access point to http://" . $self->{CONF}->{external_address} . ":" . $self->{PORT} . $self->{ENDPOINT} );
            $self->{CONF}->{"snmp"}->{"service_accesspoint"} = "http://" . $self->{CONF}->{external_address} . ":" . $self->{PORT} . $self->{ENDPOINT};
        }

        unless ( exists $self->{CONF}->{"snmp"}->{"service_description"}
            and $self->{CONF}->{"snmp"}->{"service_description"} )
        {
            my $description = "perfSONAR_PS SNMP MA";
            if ( $self->{CONF}->{site_name} ) {
                $description .= " at " . $self->{CONF}->{site_name};
            }
            if ( $self->{CONF}->{site_location} ) {
                $description .= " in " . $self->{CONF}->{site_location};
            }
            $self->{CONF}->{"snmp"}->{"service_description"} = $description;
            $self->{LOGGER}->warn( "Setting 'service_description' to '$description'." );
        }

        unless ( exists $self->{CONF}->{"snmp"}->{"service_name"}
            and $self->{CONF}->{"snmp"}->{"service_name"} )
        {
            $self->{CONF}->{"snmp"}->{"service_name"} = "SNMP MA";
            $self->{LOGGER}->warn( "Setting 'service_name' to 'SNMP MA'." );
        }

        unless ( exists $self->{CONF}->{"snmp"}->{"service_type"}
            and $self->{CONF}->{"snmp"}->{"service_type"} )
        {
            $self->{CONF}->{"snmp"}->{"service_type"} = "MA";
            $self->{LOGGER}->warn( "Setting 'service_type' to 'MA'." );
        }
    }

    unless ( exists $self->{CONF}->{"snmp"}->{"maintenance_interval"} ) {
        $self->{LOGGER}->debug( "Configuration value 'maintenance_interval' not present.  Searching for other values..." );

        unless ( exists $self->{CONF}->{"snmp"}->{"maintenance_interval"} ) {
            $self->{CONF}->{"snmp"}->{"maintenance_interval"} = 30;
        }
    }
    $self->{LOGGER}->debug( "Setting 'maintenance_interval' to \"" . $self->{CONF}->{"snmp"}->{"maintenance_interval"} . "\" minutes." );
    $self->{CONF}->{"snmp"}->{"maintenance_interval"} *= 60;

    $self->{CONF}->{"snmp"}->{"ls_chunk"} = 50;
    $handler->registerMessageHandler( "SetupDataRequest",   $self );
    $handler->registerMessageHandler( "MetadataKeyRequest", $self );
    $handler->registerMessageHandler( "DataInfoRequest",    $self );

    my $error = q{};
    if ( exists $self->{CONF}->{"snmp"}->{"metadata_db_external"}
        and $self->{CONF}->{"snmp"}->{"metadata_db_external"} )
    {
        if ( $self->{CONF}->{"snmp"}->{"metadata_db_external"} eq "none" ) {

            # do nothing
        }
        elsif ( $self->{CONF}->{"snmp"}->{"metadata_db_external"} eq "ganglia" ) {
            eval { load perfSONAR_PS::DB::Ganglia; };
            if ( $EVAL_ERROR ) {
                $self->{LOGGER}->fatal( "Cannot load \"perfSONAR_PS::DB::Ganglia\", aborting: " . $EVAL_ERROR );
                return -1;
            }
        }
        elsif ( $self->{CONF}->{"snmp"}->{"metadata_db_external"} eq "cricket" ) {

            # We need to check to be sure we can find cricket, this may be an env variable...

            if ( ( defined $ENV{CRICKET_HOME} and -d $ENV{CRICKET_HOME} ) or ( exists $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_home"} and $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_home"} ) ) {

                # try to set the other variables based on the env/first if they are not already set

                unless ( exists $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_home"} and $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_home"} ) {
                    $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_home"} = $ENV{CRICKET_HOME};
                    $self->{LOGGER}->error( "Setting the value of 'metadata_db_external_cricket_home' to \"" . $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_home"} . "\"" );
                }

                unless ( exists $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_cricket"} and $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_cricket"} ) {
                    $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_cricket"} = $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_home"} . "/cricket";
                    $self->{LOGGER}->error( "Setting the value of 'metadata_db_external_cricket_cricket' to \"" . $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_cricket"} . "\"" );
                }

                unless ( exists $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_data"} and $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_data"} ) {
                    $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_data"} = $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_home"} . "/cricket-data";
                    $self->{LOGGER}->error( "Setting the value of 'metadata_db_external_cricket_data' to \"" . $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_data"} . "\"" );
                }

                unless ( exists $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_config"} and $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_config"} ) {
                    $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_config"} = $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_home"} . "/cricket-config";
                    $self->{LOGGER}->error( "Setting the value of 'metadata_db_external_cricket_config' to \"" . $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_config"} . "\"" );
                }

                unless ( exists $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_hints"} and $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_hints"} ) {
                    $self->{LOGGER}->info( "Cricket 'metadata_db_external_cricket_hints' not specified, skipping." );
                }
            }
            else {
                $self->{LOGGER}->fatal( "Cannot find cricket; please set environmental variable CRICKET_HOME or 'metadata_db_external_cricket_home' in the configuration file." );
                return -1;
            }

            eval { load perfSONAR_PS::DB::Cricket; };
            if ( $EVAL_ERROR ) {
                $self->{LOGGER}->fatal( "Cannot load \"perfSONAR_PS::DB::Cricket\", aborting: " . $EVAL_ERROR );
                return -1;
            }
        }
        elsif ( $self->{CONF}->{"snmp"}->{"metadata_db_external"} eq "cacti" ) {
            eval { load perfSONAR_PS::DB::Cacti; };
            if ( $EVAL_ERROR ) {
                $self->{LOGGER}->fatal( "Cannot load \"perfSONAR_PS::DB::Cacti\", aborting: " . $EVAL_ERROR );
                return -1;
            }

        }
        else {
            $self->{LOGGER}->fatal( "External monitoring source \"" . $self->{CONF}->{"snmp"}->{"metadata_db_external"} . "\" not currently supported." );
            return -1;
        }

        $self->createStorage( {} );
    }

    if ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "file" ) {
        my $status = $self->refresh_store_file( { error => \$error } );
        unless ( $status == 0 ) {
            $self->{LOGGER}->fatal( "Couldn't initialize store file: $error" );
            return -1;
        }
    }
    elsif ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "sqlite" ) {
        #make sure database is created
        my $metadatadb = $self->prepareSQLiteDatabases;
        unless ( $metadatadb ) {
            $self->{LOGGER}->fatal( "There was an error opening \"" . $self->{CONF}->{"snmp"}->{"metadata_db_file"});
            return -1;
        }
        
        my ( $status, $res ) = $self->buildHashedKeys( { metadatadb => $metadatadb, metadatadb_type => "sqlite" } );
        unless ( $status == 0 ) {
            $self->{LOGGER}->fatal( "Error building key database: $res" );
            return -1;
        }

        $self->{HASH_TO_ID} = $res->{hash_to_id};
        $self->{ID_TO_HASH} = $res->{id_to_hash};
        
        $metadatadb->closeDB();
        $self->{METADATADB} = q{};
    }
    else {
        $self->{LOGGER}->fatal( "Wrong value for 'metadata_db_type' set." );
        return -1;
    }

    return 0;
}

=head2 createStorage( $self { error } )

Function to re-create the storage (store.xml) file on a regular basis.  

=cut

sub createStorage {
    my ( $self, @args ) = @_;
    my $parameters = validateParams( @args, { error => 0 } );

    if ( $self->{CONF}->{"snmp"}->{"metadata_db_external"} eq "none" ) {
        return 0;
    }

    my $tmp_file;

    if ( $self->{CONF}->{"snmp"}->{"metadata_db_external"} eq "ganglia" ) {
        $tmp_file = $self->{CONF}->{"snmp"}->{"metadata_db_file"} . ".tmp";
        my $ganglia = new perfSONAR_PS::DB::Ganglia( { rrd => $self->{CONF}->{"snmp"}->{"rrdtool"}, conf => $self->{CONF}->{"snmp"}->{"metadata_db_external_source"}, file => $tmp_file } );
        unless ( $ganglia->openDB() > -1 ) {
            $self->{LOGGER}->fatal( "Problem reading ganglia database." );
            return -1;
        }
        $ganglia->closeDB();
    }
    elsif ( $self->{CONF}->{"snmp"}->{"metadata_db_external"} eq "cricket" ) {
        $tmp_file = $self->{CONF}->{"snmp"}->{"metadata_db_file"} . ".tmp";

        my $cricket = new perfSONAR_PS::DB::Cricket(
            {
                file    => $tmp_file,
                home    => $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_home"},
                install => $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_cricket"},
                data    => $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_data"},
                config  => $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_config"},
                hints   => $self->{CONF}->{"snmp"}->{"metadata_db_external_cricket_hints"}
            }
        );
        unless ( $cricket->openDB() > -1 ) {
            $self->{LOGGER}->fatal( "Problem reading cricket database." );
            return -1;
        }
        $cricket->closeDB();
    }
    elsif ( $self->{CONF}->{"snmp"}->{"metadata_db_external"} eq "cacti" ) {
        $tmp_file = $self->{CONF}->{"snmp"}->{"metadata_db_file"} . ".tmp";

        my $cacti_host     = $self->{CONF}->{snmp}->{cacti_host};
        my $cacti_database = $self->{CONF}->{snmp}->{cacti_database};
        my $cacti_username = $self->{CONF}->{snmp}->{cacti_username};
        my $cacti_password = $self->{CONF}->{snmp}->{cacti_password};

        my $cacti = new perfSONAR_PS::DB::Cacti( { db_host => $cacti_host, db_name => $cacti_database, db_user => $cacti_username, db_pass => $cacti_password, file => $tmp_file } );
        unless ( $cacti->openDB() > -1 ) {
            $self->{LOGGER}->fatal( "Problem reading cacti database." );
            return -1;
        }
        $cacti->closeDB();
    }

    if ( -f $tmp_file ) {
        my $current_md5;
        my $new_md5;

        if ( open( FILE1, $self->{CONF}->{"snmp"}->{"metadata_db_file"} ) ) {
            binmode( FILE1 );
            $current_md5 = Digest::MD5->new->addfile( *FILE1 )->hexdigest;
            close( FILE1 );
        }

        if ( open( FILE2, $tmp_file ) ) {
            binmode( FILE2 );
            $new_md5 = Digest::MD5->new->addfile( *FILE2 )->hexdigest;
            close( FILE2 );
        }

        if ( not $current_md5 or $current_md5 ne $new_md5 ) {
            $self->{LOGGER}->debug( "Updating store file" );
            move( $tmp_file, $self->{CONF}->{"snmp"}->{"metadata_db_file"} );
        }
        else {
            $self->{LOGGER}->debug( "newly generated file is the same as is currently loaded: $new_md5/$current_md5" );
            system( "rm -f " . $tmp_file );
        }
    }

    return 0;
}

=head2 maintenance( $self )

Stub function indicating that we have 'maintenance' functions in this particular service.

=cut

sub maintenance {
    my ( $self, @args ) = @_;
    my $parameters = validateParams( @args, {} );

    return $self->{CONF}->{"snmp"}->{"maintenance_interval"};
}

=head2 inline_maintenance( $self )

Stub function to call the process that will re-generate the store file.  

=cut

sub inline_maintenance {
    my ( $self, @args ) = @_;
    my $parameters = validateParams( @args, {} );

    $self->refresh_store_file();
}

=head2 refresh_store_file( $self  {error } )

Regenerate the store file if it has gotten old.  

=cut

sub refresh_store_file {
    my ( $self, @args ) = @_;
    my $parameters = validateParams( @args, { error => 0 } );
    
    #sqlite has no store file to refresh
    if($self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "sqlite"){
        return 0;
    }
    
    my $store_file = $self->{CONF}->{"snmp"}->{"metadata_db_file"};

    if ( -f $store_file ) {
        my ( $mtime ) = ( stat( $store_file ) )[9];
        if ( $self->{BAD_MTIME} and $mtime == $self->{BAD_MTIME} ) {
            my $msg = "Previously seen bad store file";
            $self->{LOGGER}->error( $msg );
            ${ $parameters->{error} } = $msg if ( $parameters->{error} );
            return -1;
        }

        $self->{LOGGER}->debug( "New: $mtime Old: " . $self->{STORE_FILE_MTIME} ) if ( $mtime and $self->{STORE_FILE_MTIME} );

        unless ( $self->{STORE_FILE_MTIME} and $self->{STORE_FILE_MTIME} == $mtime ) {
            my $error;
            my $new_metadatadb = perfSONAR_PS::DB::File->new( { file => $store_file } );
            $new_metadatadb->openDB( { error => \$error } );
            unless ( $new_metadatadb ) {
                my $msg = "Couldn't initialize store file: $error";
                $self->{LOGGER}->error( $msg );
                ${ $parameters->{error} } = $msg if ( $parameters->{error} );
                $self->{BAD_MTIME} = $mtime;
                return -1;
            }

            my ( $status, $res ) = $self->buildHashedKeys( { metadatadb => $new_metadatadb, metadatadb_type => "file" } );
            unless ( $status == 0 ) {
                my $msg = "Error building key database: $res";
                $self->{LOGGER}->fatal( $msg );
                ${ $parameters->{error} } = $msg if ( $parameters->{error} );
                $self->{BAD_MTIME} = $mtime;
                return -1;
            }

            $self->{METADATADB}       = $new_metadatadb;
            $self->{HASH_TO_ID}       = $res->{hash_to_id};
            $self->{ID_TO_HASH}       = $res->{id_to_hash};
            $self->{STORE_FILE_MTIME} = $mtime;
            $self->{LOGGER}->debug( "Setting mtime to $mtime" );
        }
    }

    ${ $parameters->{error} } = "" if ( $parameters->{error} );
    return 0;
}

=head2 prepareSQLiteDatabases($self)

Opens the SQLite metadata database

=cut
sub prepareSQLiteDatabases {
    my $self = shift @_;

    #create database
    my $metadatadb = new perfSONAR_PS::DB::SQL( { name => "dbi:SQLite:dbname=" . $self->{CONF}->{"snmp"}->{"metadata_db_file"}, user => '', pass => '' } );
    unless ( $metadatadb->openDB() == 0 ) {
        throw perfSONAR_PS::Error_compat( "error.snmp.sqlite", "There was an error opening " . $self->{CONF}->{"snmp"}->{"metadata_db_file"} );
        return;
    }
    
    return $metadatadb;
}

=head2 buildHashedKeys($self {})

With the backend storage known we can search through looking for key
structures.  Once we have these in hand each will be examined and Digest::MD5
will be utilized to create MD5 hex based fingerprints of each key.  We then 
map these to the key ids in the metadata database for easy lookup.

=cut

sub buildHashedKeys {
    my ( $self, @args ) = @_;
    my $parameters = validateParams( @args, { metadatadb => 1, metadatadb_type => 1 } );

    my %hash_to_id = ();
    my %id_to_hash = ();

    my $metadatadb      = $parameters->{metadatadb};
    my $metadatadb_type = $parameters->{metadatadb_type};

    if ( $metadatadb_type eq "file" ) {
        my $results = $metadatadb->querySet( { query => "/nmwg:store/nmwg:data" } );
        if ( $results->size() > 0 ) {
            foreach my $data ( $results->get_nodelist ) {
                if ( $data->getAttribute( "id" ) ) {
                    my $hash = md5_hex( $data->toString );
                    $hash_to_id{$hash} = $data->getAttribute( "id" );
                    $id_to_hash{ $data->getAttribute( "id" ) } = $hash;
                    $self->{LOGGER}->debug( "Key id $hash maps to data element " . $data->getAttribute( "id" ) );
                }
            }
        }
    }
    elsif ( $metadatadb_type eq "sqlite" ) {
         my $metadatadb = $self->prepareSQLiteDatabases();
         unless ( $metadatadb ) {
            $self->{LOGGER}->fatal( "Database could not be opened." );
            return -1;
        }
        
         my $results = $metadatadb->query({ query => "SELECT * FROM dataKeys" });
         if( $results == -1 ){
            $metadatadb->closeDB();
            return -1;
         }
         
         foreach my $result( @{$results} ){
             my $hash = md5_hex( join '', @{$result} );
             $hash_to_id{$hash} = 'data' . $result->[0];
             $id_to_hash{'data' . $result->[0] } = $hash;
         }
         $metadatadb->closeDB();
    }
    else {
        my $msg = "Wrong value for 'metadata_db_type' set.";
        $self->{LOGGER}->fatal( $msg );
        return ( -1, $msg );
    }

    my %retval = (
        id_to_hash => \%id_to_hash,
        hash_to_id => \%hash_to_id,
    );

    return ( 0, \%retval );
}

=head2 needLS($self {})

This particular service (SNMP MA) should register with a lookup service.  This
function simply returns the value set in the configuration file (either yes or
no, depending on user preference) to let other parts of the framework know if
LS registration is required.

=cut

sub needLS {
    my ( $self, @args ) = @_;
    my $parameters = validateParams( @args, {} );

    return $self->{CONF}->{"snmp"}->{enable_registration};
}

=head2 registerLS($self $sleep_time)

Given the service information (specified in configuration) and the contents of
our metadata database, we can contact the specified LS and register ourselves.
We then sleep for some amount of time and do it again.

=cut

sub registerLS {
    my ( $self, $sleep_time ) = validateParamsPos( @_, 1, { type => SCALARREF }, );

    if ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "file" ) {
        unless ( -f $self->{CONF}->{"snmp"}->{"metadata_db_file"} ) {
            $self->{LOGGER}->fatal( "Store file not defined, disallowing registration." );
            return -1;
        }
    }
    elsif ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "sqlite" ) {
        unless ( -f $self->{CONF}->{"snmp"}->{"metadata_db_file"} ) {
            $self->{LOGGER}->fatal( "Store file not defined, disallowing registration." );
            return -1;
        }
    }
    else {
        $self->{LOGGER}->fatal( "Metadata database is not configured, disallowing registration." );
        return -1;
    }

    my ( $status, $res );
    my $ls = q{};

    my @ls_array = ();
    my @array = split( /\s+/, $self->{CONF}->{"snmp"}->{"ls_instance"} );
    foreach my $l ( @array ) {
        $l =~ s/(\s|\n)*//g;
        push @ls_array, $l if $l;
    }
    @array = split( /\s+/, $self->{CONF}->{"ls_instance"} );
    foreach my $l ( @array ) {
        $l =~ s/(\s|\n)*//g;
        push @ls_array, $l if $l;
    }

    my @hints_array = ();
    @array = split( /\s+/, $self->{CONF}->{"root_hints_url"} );
    foreach my $h ( @array ) {
        $h =~ s/(\s|\n)*//g;
        push @hints_array, $h if $h;
    }

    unless ( exists $self->{LS_CLIENT} and $self->{LS_CLIENT} ) {
        my %ls_conf = (
            SERVICE_TYPE        => $self->{CONF}->{"snmp"}->{"service_type"},
            SERVICE_NAME        => $self->{CONF}->{"snmp"}->{"service_name"},
            SERVICE_DESCRIPTION => $self->{CONF}->{"snmp"}->{"service_description"},
            SERVICE_ACCESSPOINT => $self->{CONF}->{"snmp"}->{"service_accesspoint"},
        );
        $self->{LS_CLIENT} = new perfSONAR_PS::Client::LS::Remote( \@ls_array, \%ls_conf, \@hints_array );
    }

    $ls = $self->{LS_CLIENT};

    my $error         = q{};
    my @resultsString = ();
    if ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "file" ) {
        @resultsString = $self->{METADATADB}->query( { query => "/nmwg:store/nmwg:metadata", error => \$error } );
    }
    elsif ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "sqlite" ) {
        my $metadatadb = $self->prepareSQLiteDatabases;
        unless ( $metadatadb ) {
            $self->{LOGGER}->fatal( "Database could not be opened." );
            return -1;
        }
        my $resultsXMLObj = $self->sqLiteCreateMetadata( { metadatadb => $metadatadb } );
        foreach my $md ( $resultsXMLObj->get_nodelist ){
            push @resultsString, $md->toString;
        }
        $metadatadb->closeDB();
    }
    else {
        $self->{LOGGER}->fatal( "Wrong value for 'metadata_db_type' set." );
        return -1;
    }

    if ( $#resultsString == -1 ) {
        $self->{LOGGER}->warn( "No data to register with LS" );
        return -1;
    }
    $ls->registerStatic( \@resultsString );
    return 0;
}

=head2 handleMessageBegin($self, { ret_message, messageId, messageType, msgParams, request, retMessageType, retMessageNamespaces })

Stub function that is currently unused.  Will be used to interact with the 
daemon's message handler.

=cut

sub handleMessageBegin {
    my ( $self, $ret_message, $messageId, $messageType, $msgParams, $request, $retMessageType, $retMessageNamespaces ) = @_;

    #   my ($self, @args) = @_;
    #      my $parameters = validateParams(@args,
    #            {
    #                ret_message => 1,
    #                messageId => 1,
    #                messageType => 1,
    #                msgParams => 1,
    #                request => 1,
    #                retMessageType => 1,
    #                retMessageNamespaces => 1
    #            });

    return 0;
}

=head2 handleMessageEnd($self, { ret_message, messageId })

Stub function that is currently unused.  Will be used to interact with the 
daemon's message handler.

=cut

sub handleMessageEnd {
    my ( $self, $ret_message, $messageId ) = @_;

    #   my ($self, @args) = @_;
    #      my $parameters = validateParams(@args,
    #            {
    #                ret_message => 1,
    #                messageId => 1
    #            });

    return 0;
}

=head2 handleEvent($self, { output, messageId, messageType, messageParameters, eventType, subject, filterChain, data, rawRequest, doOutputMetadata })

Current workaround to the daemon's message handler.  All messages that enter
will be routed based on the message type.  The appropriate solution to this
problem is to route on eventType and message type and will be implemented in
future releases.

=cut

sub handleEvent {
    my ( $self, @args ) = @_;
    my $parameters = validateParams(
        @args,
        {
            output            => 1,
            messageId         => 1,
            messageType       => 1,
            messageParameters => 1,
            eventType         => 1,
            subject           => 1,
            filterChain       => 1,
            data              => 1,
            rawRequest        => 1,
            doOutputMetadata  => 1,
        }
    );
    my $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.handleEvent.start", { messageType => $parameters->{messageType}, } );
    $self->{NETLOGGER}->debug( $msg );

    my @subjects = @{ $parameters->{subject} };
    my @filters  = @{ $parameters->{filterChain} };
    my $md       = $subjects[0];

    # this module outputs its own metadata so it needs to turn off the daemon's
    # metadata output routines.
    ${ $parameters->{doOutputMetadata} } = 0;

    my %timeSettings = ();

    # go through the main subject and select filters looking for parameters.
    my $new_timeSettings = getFilterParameters( { m => $md, namespaces => $parameters->{rawRequest}->getNamespaces(), default_resolution => $self->{CONF}->{"snmp"}->{"default_resolution"} } );

    $timeSettings{"CF"}                   = $new_timeSettings->{"CF"}                   if ( defined $new_timeSettings->{"CF"} );
    $timeSettings{"RESOLUTION"}           = $new_timeSettings->{"RESOLUTION"}           if ( defined $new_timeSettings->{"RESOLUTION"} and $timeSettings{"RESOLUTION_SPECIFIED"} );
    $timeSettings{"RESOLUTION_SPECIFIED"} = $new_timeSettings->{"RESOLUTION_SPECIFIED"} if ( $new_timeSettings->{"RESOLUTION_SPECIFIED"} );

    if ( exists $new_timeSettings->{"START"}->{"value"} ) {
        if ( exists $new_timeSettings->{"START"}->{"type"} and lc( $new_timeSettings->{"START"}->{"type"} ) eq "unix" ) {
            $new_timeSettings->{"START"}->{"internal"} = $new_timeSettings->{"START"}->{"value"};
        }
        elsif ( exists $new_timeSettings->{"START"}->{"type"} and lc( $new_timeSettings->{"START"}->{"type"} ) eq "iso" ) {
            $new_timeSettings->{"START"}->{"internal"} = UnixDate( $new_timeSettings->{"START"}->{"value"}, "%s" );
        }
        else {
            $new_timeSettings->{"START"}->{"internal"} = $new_timeSettings->{"START"}->{"value"};
        }
    }
    $timeSettings{"START"} = $new_timeSettings->{"START"};

    if ( exists $new_timeSettings->{"END"}->{"value"} ) {
        if ( exists $new_timeSettings->{"END"}->{"type"} and lc( $new_timeSettings->{"END"}->{"type"} ) eq "unix" ) {
            $new_timeSettings->{"END"}->{"internal"} = $new_timeSettings->{"END"}->{"value"};
        }
        elsif ( exists $new_timeSettings->{"START"}->{"type"} and lc( $new_timeSettings->{"END"}->{"type"} ) eq "iso" ) {
            $new_timeSettings->{"END"}->{"internal"} = UnixDate( $new_timeSettings->{"END"}->{"value"}, "%s" );
        }
        else {
            $new_timeSettings->{"END"}->{"internal"} = $new_timeSettings->{"END"}->{"value"};
        }
    }
    $timeSettings{"END"} = $new_timeSettings->{"END"};

    if ( $#filters > -1 ) {
        foreach my $filter_arr ( @filters ) {
            my @filters = @{$filter_arr};
            my $filter  = $filters[-1];

            $new_timeSettings = getFilterParameters( { m => $filter, namespaces => $parameters->{rawRequest}->getNamespaces(), default_resolution => $self->{CONF}->{"snmp"}->{"default_resolution"} } );

            $timeSettings{"CF"}                   = $new_timeSettings->{"CF"}                   if ( defined $new_timeSettings->{"CF"} );
            $timeSettings{"RESOLUTION"}           = $new_timeSettings->{"RESOLUTION"}           if ( defined $new_timeSettings->{"RESOLUTION"} and $new_timeSettings->{"RESOLUTION_SPECIFIED"} );
            $timeSettings{"RESOLUTION_SPECIFIED"} = $new_timeSettings->{"RESOLUTION_SPECIFIED"} if ( $new_timeSettings->{"RESOLUTION_SPECIFIED"} );

            if ( exists $new_timeSettings->{"START"}->{"value"} ) {
                if ( exists $new_timeSettings->{"START"}->{"type"} and lc( $new_timeSettings->{"START"}->{"type"} ) eq "unix" ) {
                    $new_timeSettings->{"START"}->{"internal"} = $new_timeSettings->{"START"}->{"value"};
                }
                elsif ( exists $new_timeSettings->{"START"}->{"type"} and lc( $new_timeSettings->{"START"}->{"type"} ) eq "iso" ) {
                    $new_timeSettings->{"START"}->{"internal"} = UnixDate( $new_timeSettings->{"START"}->{"value"}, "%s" );
                }
                else {
                    $new_timeSettings->{"START"}->{"internal"} = $new_timeSettings->{"START"}->{"value"};
                }
            }
            else {
                $new_timeSettings->{"START"}->{"internal"} = q{};
            }

            if ( exists $new_timeSettings->{"END"}->{"value"} ) {
                if ( exists $new_timeSettings->{"END"}->{"type"} and lc( $new_timeSettings->{"END"}->{"type"} ) eq "unix" ) {
                    $new_timeSettings->{"END"}->{"internal"} = $new_timeSettings->{"END"}->{"value"};
                }
                elsif ( exists $new_timeSettings->{"END"}->{"type"} and lc( $new_timeSettings->{"END"}->{"type"} ) eq "iso" ) {
                    $new_timeSettings->{"END"}->{"internal"} = UnixDate( $new_timeSettings->{"END"}->{"value"}, "%s" );
                }
                else {
                    $new_timeSettings->{"END"}->{"internal"} = $new_timeSettings->{"END"}->{"value"};
                }
            }
            else {
                $new_timeSettings->{"END"}->{"internal"} = q{};
            }

            # we conditionally replace the START/END settings since under the
            # theory of filter, if a later element specifies an earlier start
            # time, the later start time that appears higher in the filter chain
            # would have filtered out all times earlier than itself leaving
            # nothing to exist between the earlier start time and the later
            # start time. XXX I'm not sure how the resolution and the
            # consolidation function should work in this context.

            if ( exists $new_timeSettings->{"START"}->{"internal"} and ( ( not exists $timeSettings{"START"}->{"internal"} ) or $new_timeSettings->{"START"}->{"internal"} > $timeSettings{"START"}->{"internal"} ) ) {
                $timeSettings{"START"} = $new_timeSettings->{"START"};
            }

            if ( exists $new_timeSettings->{"END"}->{"internal"} and ( ( not exists $timeSettings{"END"}->{"internal"} ) or $new_timeSettings->{"END"}->{"internal"} < $timeSettings{"END"}->{"internal"} ) ) {
                $timeSettings{"END"} = $new_timeSettings->{"END"};
            }
        }
    }

    # If no resolution was listed in the filters, go with the default
    if ( not defined $timeSettings{"RESOLUTION"} ) {
        $timeSettings{"RESOLUTION"}           = $self->{CONF}->{"snmp"}->{"default_resolution"};
        $timeSettings{"RESOLUTION_SPECIFIED"} = 0;
    }

    my $cf         = q{};
    my $resolution = q{};
    my $start      = q{};
    my $end        = q{};

    $cf         = $timeSettings{"CF"}                  if ( $timeSettings{"CF"} );
    $resolution = $timeSettings{"RESOLUTION"}          if ( $timeSettings{"RESOLUTION"} );
    $start      = $timeSettings{"START"}->{"internal"} if ( $timeSettings{"START"}->{"internal"} );
    $end        = $timeSettings{"END"}->{"internal"}   if ( $timeSettings{"END"}->{"internal"} );

    $self->{LOGGER}->debug( "Request filter parameters: cf: $cf resolution: $resolution start: $start end: $end" );

    if ( $parameters->{messageType} eq "MetadataKeyRequest" ) {
        $self->{LOGGER}->info( "MetadataKeyRequest initiated." );
        $self->maMetadataKeyRequest(
            {
                output             => $parameters->{output},
                metadata           => $md,
                filters            => \@filters,
                time_settings      => \%timeSettings,
                request            => $parameters->{rawRequest},
                message_parameters => $parameters->{messageParameters}
            }
        );
    }
    elsif ( $parameters->{messageType} eq "SetupDataRequest" ) {
        $self->{LOGGER}->info( "SetupDataRequest initiated." );
        $self->maSetupDataRequest(
            {
                output             => $parameters->{output},
                metadata           => $md,
                filters            => \@filters,
                time_settings      => \%timeSettings,
                request            => $parameters->{rawRequest},
                message_parameters => $parameters->{messageParameters}
            }
        );
    }
    elsif ( $parameters->{messageType} eq "DataInfoRequest" ) {
        $self->{LOGGER}->info( "DataInfoRequest initiated." );
        $self->maDataInfoRequest(
            {
                output             => $parameters->{output},
                metadata           => $md,
                filters            => \@filters,
                time_settings      => \%timeSettings,
                request            => $parameters->{rawRequest},
                message_parameters => $parameters->{messageParameters}
            }
        );
    }
    else {
        throw perfSONAR_PS::Error_compat( "error.ma.message_type", "Invalid Message Type" );
    }
    $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.handleEvent.end" );
    $self->{NETLOGGER}->debug( $msg );
    return;
}

=head2 maMetadataKeyRequest($self, { output, metadata, time_settings, filters, request, message_parameters })

Main handler of MetadataKeyRequest messages.  Based on contents (i.e. was a
key sent in the request, or not) this will route to one of two functions:

 - metadataKeyRetrieveKey          - Handles all requests that enter with a 
                                     key present.  
 - metadataKeyRetrieveMetadataData - Handles all other requests
 
The goal of this message type is to return a pointer (i.e. a 'key') to the data
so that the more expensive operation of XPath searching the database is avoided
with a simple hashed key lookup.  The key currently can be replayed repeatedly
currently because it is not time sensitive.  

=cut

sub maMetadataKeyRequest {
    my ( $self, @args ) = @_;
    my $parameters = validateParams(
        @args,
        {
            output             => 1,
            metadata           => 1,
            time_settings      => 1,
            filters            => 1,
            request            => 1,
            message_parameters => 1
        }
    );

    my $mdId  = q{};
    my $dId   = q{};
    my $error = q{};
    if ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "sqlite" ) {
        $self->{METADATADB} = $self->prepareSQLiteDatabases();
        unless ( $self->{METADATADB} ) {
            throw perfSONAR_PS::Error_compat( "SQLite database could not be opened." );
            return;
        }
    }elsif( $self->{CONF}->{"snmp"}->{"metadata_db_type"} ne "file" ){
        throw perfSONAR_PS::Error_compat( "Wrong value for 'metadata_db_type' set." );
        return;
    }

    my $nmwg_key = find( $parameters->{metadata}, "./nmwg:key", 1 );
    if ( $nmwg_key ) {
        $self->{LOGGER}->info( "Key found - running MetadataKeyRequest with existing key." );
        $self->metadataKeyRetrieveKey(
            {
                metadatadb         => $self->{METADATADB},
                key                => $nmwg_key,
                metadata           => $parameters->{metadata},
                filters            => $parameters->{filters},
                request_namespaces => $parameters->{request}->getNamespaces(),
                output             => $parameters->{output}
            }
        );
    }
    else {
        $self->{LOGGER}->info( "Key not found - running MetadataKeyRequest without a key." );
        $self->metadataKeyRetrieveMetadataData(
            {
                metadatadb         => $self->{METADATADB},
                time_settings      => $parameters->{time_settings},
                metadata           => $parameters->{metadata},
                filters            => $parameters->{filters},
                request_namespaces => $parameters->{request}->getNamespaces(),
                output             => $parameters->{output}
            }
        );

    }

    return;
}

=head2 metadataKeyRetrieveKey($self, { metadatadb, key, metadata, filters, request_namespaces, output })

Because the request entered with a key, we must handle it in this particular
function.  We first attempt to extract the 'maKey' hash and check for validity.
An invalid or missing key will trigger an error instantly.  If the key is found
we see if any chaining needs to be done (and appropriately 'cook' the key), then
return the response.

=cut

sub metadataKeyRetrieveKey {
    my ( $self, @args ) = @_;
    my $parameters = validateParams(
        @args,
        {
            metadatadb         => 1,
            key                => 1,
            metadata           => 1,
            filters            => 1,
            request_namespaces => 1,
            output             => 1
        }
    );

    my $mdId    = "metadata." . genuid();
    my $dId     = "data." . genuid();
    my $hashKey = extract( find( $parameters->{key}, ".//nmwg:parameter[\@name=\"maKey\"]", 1 ), 0 );
    unless ( $hashKey ) {
        my $msg = "Key error in metadata storage - key format is incorrect.";
        $self->{LOGGER}->error( $msg );
        throw perfSONAR_PS::Error_compat( "error.ma.storage_result", $msg );
        return;
    }

    my $hashId = $self->{HASH_TO_ID}->{$hashKey};
    unless ( $hashId ) {
        my $msg = "Key error in metadata storage - key not found.";
        $self->{LOGGER}->error( $msg );
        throw perfSONAR_PS::Error_compat( "error.ma.storage_result", $msg );
        return;
    }

    my $query = q{};
    if ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "file" ) {
        $query = "/nmwg:store/nmwg:data[\@id=\"" . $hashId . "\"]";
    }

    $self->{LOGGER}->debug( "Running query \"" . $query . "\"" );

    if ( $parameters->{metadatadb}->count( { query => $query } ) != 1 ) {
        my $msg = "Key error in metadata storage - key not found in database.";
        $self->{LOGGER}->error( $msg );
        throw perfSONAR_PS::Error_compat( "error.ma.storage_result", $msg );
        return;
    }

    my $mdIdRef;
    my @filters = @{ $parameters->{filters} };
    if ( $#filters > -1 ) {
        $mdIdRef = $filters[-1][0]->getAttribute( "id" );
    }
    else {
        $mdIdRef = $parameters->{metadata}->getAttribute( "id" );
    }

    createMetadata( $parameters->{output}, $mdId, $mdIdRef, $parameters->{key}->toString, undef );
    my $key2 = $parameters->{key}->cloneNode( 1 );
    my $params = find( $key2, ".//nmwg:parameters", 1 );
    $self->addSelectParameters( { parameter_block => $params, filters => $parameters->{filters} } );
    createData( $parameters->{output}, $dId, $mdId, $key2->toString, undef );
    return;
}

=head2 metadataKeyRetrieveMetadataData($self, $metadatadb, $metadata, $chain,
                                       $id, $request_namespaces, $output)

Similar to 'metadataKeyRetrieveKey' we are looking to return a valid key.  The
input will be partially or fully specified metadata.  If this matches something
in the database we will return a key matching the description (in the form of
an MD5 fingerprint).  If this metadata was a part of a chain the chaining will
be resolved and used to augment (i.e. 'cook') the key.

=cut

sub metadataKeyRetrieveMetadataData {
    my ( $self, @args ) = @_;
    my $parameters = validateParams(
        @args,
        {
            metadatadb         => 1,
            time_settings      => 1,
            metadata           => 1,
            filters            => 1,
            request_namespaces => 1,
            output             => 1
        }
    );

    my $mdId        = q{};
    my $dId         = q{};
    my $queryString = q{};
    my $results     = q{};
    my $dataResults = q{};

    if( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "sqlite" ){
        $results = $self->sqLiteCreateMetadata({ metadatadb => $parameters->{metadatadb}, node => $parameters->{metadata} });
        my @mdIds = ();
        foreach my $md ( $results->get_nodelist ) {
            my $tmpMdId = $md->getAttribute( "id" );
            $tmpMdId =~ s/meta//;
            push @mdIds,  $tmpMdId;
        }
        $dataResults = $self->sqLiteCreateKeyData({ metadatadb => $parameters->{metadatadb}, metaDataIds => \@mdIds });
    }else{
        if ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "file" ) {
            $queryString = "/nmwg:store/nmwg:metadata[" . getMetadataXQuery( { node => $parameters->{metadata} } ) . "]";
        }
    
        $self->{LOGGER}->debug( "Running query \"" . $queryString . "\"" );
        $results             = $parameters->{metadatadb}->querySet( { query => $queryString } );
        my %et                  = ();
        my $eventTypes          = find( $parameters->{metadata}, "./nmwg:eventType", 0 );
        my $supportedEventTypes = find( $parameters->{metadata}, ".//nmwg:parameter[\@name=\"supportedEventType\" or \@name=\"eventType\"]", 0 );
        foreach my $e ( $eventTypes->get_nodelist ) {
            my $value = extract( $e, 0 );
            if ( $value ) {
                $et{$value} = 1;
            }
        }
        foreach my $se ( $supportedEventTypes->get_nodelist ) {
            my $value = extract( $se, 0 );
            if ( $value ) {
                $et{$value} = 1;
            }
        }
    
        if ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "file" ) {
            $queryString = "/nmwg:store/nmwg:data";
        }
    
        if ( $eventTypes->size() or $supportedEventTypes->size() ) {
            $queryString = $queryString . "[./nmwg:key/nmwg:parameters/nmwg:parameter[(\@name=\"supportedEventType\" or \@name=\"eventType\")";
            foreach my $e ( sort keys %et ) {
                $queryString = $queryString . " and (\@value=\"" . $e . "\" or text()=\"" . $e . "\")";
            }
            $queryString = $queryString . "]]";
        }
        
        $self->{LOGGER}->debug( "Running query \"" . $queryString . "\"" );
        
        $dataResults = $parameters->{metadatadb}->querySet( { query => $queryString } );
    }
    
    #get request metadataId
    my $base_id = $parameters->{metadata}->getAttribute( "id" );
    my @filters = @{ $parameters->{filters} };
    if ( $#filters > -1 ) {
        my @filter_arr = @{ $filters[-1] };
        $base_id = $filter_arr[0]->getAttribute( "id" );
    }
        
    if ( $results->size() > 0 and $dataResults->size() > 0 ) {
        my %mds = ();
        foreach my $md ( $results->get_nodelist ) {
            my $curr_md_id = $md->getAttribute( "id" );
            next if not $curr_md_id;
            $mds{$curr_md_id} = $md;
        }

        foreach my $d ( $dataResults->get_nodelist ) {
            my $curr_d_mdIdRef = $d->getAttribute( "metadataIdRef" );
            next if ( not $curr_d_mdIdRef or not exists $mds{$curr_d_mdIdRef} );
            my $curr_md = $mds{$curr_d_mdIdRef};

            my $dId  = "data." . genuid();
            my $mdId = "metadata." . genuid();

            my $md_temp = $curr_md->cloneNode( 1 );
            $md_temp->setAttribute( "metadataIdRef", $base_id  );
            $md_temp->setAttribute( "id",            $mdId );

            $parameters->{output}->addExistingXMLElement( $md_temp );

            my $hashId  = $d->getAttribute( "id" );
            my $hashKey = $self->{ID_TO_HASH}->{$hashId};

            next if ( not defined $hashKey );

            startData( $parameters->{output}, $dId, $mdId, undef );
            $parameters->{output}->startElement( { prefix => "nmwg", tag => "key", namespace => "http://ggf.org/ns/nmwg/base/2.0/" } );
            startParameters( $parameters->{output}, "params.0" );
            addParameter( $parameters->{output}, "maKey", $hashKey );

            my %attrs = ();
            $attrs{"type"} = $parameters->{time_settings}->{"START"}->{"type"} if $parameters->{time_settings}->{"START"}->{"type"};
            addParameter( $parameters->{output}, "startTime", $parameters->{time_settings}->{"START"}->{"value"}, \%attrs ) if ( defined $parameters->{time_settings}->{"START"}->{"value"} );

            %attrs = ();
            $attrs{"type"} = $parameters->{time_settings}->{"END"}->{"type"} if $parameters->{time_settings}->{"END"}->{"type"};
            addParameter( $parameters->{output}, "endTime", $parameters->{time_settings}->{"END"}->{"value"}, \%attrs ) if ( defined $parameters->{time_settings}->{"END"}->{"value"} );

            if ( defined $parameters->{time_settings}->{"RESOLUTION"} and $parameters->{time_settings}->{"RESOLUTION_SPECIFIED"} ) {
                addParameter( $parameters->{output}, "resolution", $parameters->{time_settings}->{"RESOLUTION"} );
            }
            addParameter( $parameters->{output}, "consolidationFunction", $parameters->{time_settings}->{"CF"} ) if ( defined $parameters->{time_settings}->{"CF"} );
            endParameters( $parameters->{output} );
            $parameters->{output}->endElement( "key" );
            endData( $parameters->{output} );
        }
    }
    else {
        my $msg = "Database \"" . $self->{CONF}->{"snmp"}->{"metadata_db_file"} . "\" returned 0 results for search";
        $self->{LOGGER}->error( $msg );
        throw perfSONAR_PS::Error_compat( "error.ma.storage", $msg );
    }
    return;
}

=head2 maDataInfoRequest($self, { output, metadata, time_settings, filters, request, message_parameters })

Testing of a new request message to get the 'meta' metadata; e.g. information like data start/end
times in the database, resolutions, etc.

=cut

sub maDataInfoRequest {
    my ( $self, @args ) = @_;
    my $parameters = validateParams(
        @args,
        {
            output             => 1,
            metadata           => 1,
            time_settings      => 1,
            filters            => 1,
            request            => 1,
            message_parameters => 1
        }
    );

    my $mdId  = q{};
    my $dId   = q{};
    my $error = q{};
    if ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "sqlite" ) {
        $self->{METADATADB} = $self->prepareSQLiteDatabases();
        unless ( $self->{METADATADB} ) {
            throw perfSONAR_PS::Error_compat( "SQLite database could not be opened." );
            return;
        }
    }elsif( $self->{CONF}->{"snmp"}->{"metadata_db_type"} ne "file" ){
        throw perfSONAR_PS::Error_compat( "Wrong value for 'metadata_db_type' set." );
        return;
    }

    my $nmwg_key = find( $parameters->{metadata}, "./nmwg:key", 1 );
    if ( $nmwg_key ) {
        $self->{LOGGER}->info( "Key found - running DataInfoRequest with existing key." );
        $self->dataInfoRetrieveKey(
            {
                metadatadb         => $self->{METADATADB},
                key                => $nmwg_key,
                metadata           => $parameters->{metadata},
                filters            => $parameters->{filters},
                request_namespaces => $parameters->{request}->getNamespaces(),
                output             => $parameters->{output}
            }
        );
    }
    else {
        $self->{LOGGER}->info( "Key found - running DataInfoRequest with existing key." );
        $self->dataInfoRetrieveMetadataData(
            {
                metadatadb         => $self->{METADATADB},
                time_settings      => $parameters->{time_settings},
                metadata           => $parameters->{metadata},
                filters            => $parameters->{filters},
                request_namespaces => $parameters->{request}->getNamespaces(),
                output             => $parameters->{output}
            }
        );

    }

    return;
}

=head2 dataInfoRetrieveKey($self, { metadatadb, key, metadata, filters, request_namespaces, output })

Case where a key is provided

=cut

sub dataInfoRetrieveKey {
    my ( $self, @args ) = @_;
    my $parameters = validateParams(
        @args,
        {
            metadatadb         => 1,
            key                => 1,
            metadata           => 1,
            filters            => 1,
            request_namespaces => 1,
            output             => 1
        }
    );

    my $mdId    = "metadata." . genuid();
    my $dId     = "data." . genuid();
    my $results = q{};
    my $hashKey = extract( find( $parameters->{key}, ".//nmwg:parameter[\@name=\"maKey\"]", 1 ), 0 );
    unless ( $hashKey ) {
        my $msg = "Key error in metadata storage - key format is incorrect.";
        $self->{LOGGER}->error( $msg );
        throw perfSONAR_PS::Error_compat( "error.ma.storage_result", $msg );
        return;
    }

    my $hashId = $self->{HASH_TO_ID}->{$hashKey};
    unless ( $hashId ) {
        my $msg = "Key error in metadata storage - key not found.";
        $self->{LOGGER}->error( $msg );
        throw perfSONAR_PS::Error_compat( "error.ma.storage_result", $msg );
        return;
    }

    my $query = q{};
    if ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "file" ) {
        $query = "/nmwg:store/nmwg:data[\@id=\"" . $hashId . "\"]";
        $self->{LOGGER}->debug( "Running query \"" . $query . "\"" );
        $results = $parameters->{metadatadb}->querySet( { query => $query } );
    }
    elsif( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "sqlite" ){
        $results = $self->sqLiteCreateKeyData( { metadatadb => $parameters->{metadatadb}, keyId => "$hashId" } );
    }

    if ( $results->size() != 1 ) {
        my $msg = "Key error in metadata storage - key not found in database.";
        $self->{LOGGER}->error( $msg );
        throw perfSONAR_PS::Error_compat( "error.ma.storage_result", $msg );
        return;
    }

    my $mdIdRef;
    my @filters = @{ $parameters->{filters} };
    if ( $#filters > -1 ) {
        $mdIdRef = $filters[-1][0]->getAttribute( "id" );
    }
    else {
        $mdIdRef = $parameters->{metadata}->getAttribute( "id" );
    }

    # XXX jz 1/26/09
    # For now if the store file already contains the first/last time info we are
    #  going to return it as is.  We need to check to be sure this hasn't been
    #  updated by something external (e.g. cricket)

    my $done = extract( find( $results->get_node( 1 ), ".//nmwg:parameter[\@name=\"firstTime\"]", 1 ), 1 );
    if ( $done ) {
        createMetadata( $parameters->{output}, $mdId, $mdIdRef, $parameters->{key}->toString, undef );
        createData( $parameters->{output}, $dId, $mdId, $results->get_node( 1 )->toString, undef );
    }
    else {

        my $key2 = $results->get_node( 1 )->cloneNode( 1 );
        my $params = find( $key2, ".//nmwg:parameters", 1 );

        my $rrd_file = extract( find( $params, ".//nmwg:parameter[\@name=\"file\"]", 1 ), 1 );
        my $rrd = new perfSONAR_PS::DB::RRD( { path => $self->{CONF}->{"snmp"}->{"rrdtool"}, name => $rrd_file, error => 1 } );
        $rrd->openDB;
        my $first = $rrd->firstValue();
        my $last  = $rrd->lastValue();

        if ( $rrd->getErrorMessage ) {
            my $msg = "Data storage error";
            $self->{LOGGER}->error( $msg );
            throw perfSONAR_PS::Error_compat( "error.ma.storage_result", $msg );
        }
        else {
            createMetadata( $parameters->{output}, $mdId, $mdIdRef, $parameters->{key}->toString, undef );

            my $thing = XML::LibXML::Element->new( "parameter" );
            $thing->setNamespace( "http://ggf.org/ns/nmwg/base/2.0/", "nmwg", 1 );
            $thing->setAttribute( "name", "firstTime" );
            $thing->appendTextNode( $first );
            $params->addChild( $thing );
            $thing = XML::LibXML::Element->new( "parameter" );
            $thing->setNamespace( "http://ggf.org/ns/nmwg/base/2.0/", "nmwg", 1 );
            $thing->setAttribute( "name", "lastTime" );
            $thing->appendTextNode( $last );
            $params->addChild( $thing );
            $thing = XML::LibXML::Element->new( "parameter" );
            $thing->setNamespace( "http://ggf.org/ns/nmwg/base/2.0/", "nmwg", 1 );
            $thing->setAttribute( "name", "maKey" );
            $thing->appendTextNode( $hashKey );
            $params->addChild( $thing );

            $self->addSelectParameters( { parameter_block => $params, filters => $parameters->{filters} } );
            createData( $parameters->{output}, $dId, $mdId, $key2->toString, undef );
        }
        $rrd->closeDB;
    }
    return;
}

=head2 dataInfoRetrieveMetadataData($self, $metadatadb, $metadata, $chain, $id, $request_namespaces, $output)

case where no key is provided

=cut

sub dataInfoRetrieveMetadataData {
    my ( $self, @args ) = @_;
    my $parameters = validateParams(
        @args,
        {
            metadatadb         => 1,
            time_settings      => 1,
            metadata           => 1,
            filters            => 1,
            request_namespaces => 1,
            output             => 1
        }
    );

    my $mdId        = q{};
    my $dId         = q{};
    my $queryString = q{};
    my $results     = q{};
    my $dataResults = q{};
    
    if( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "sqlite" ){
        $results = $self->sqLiteCreateMetadata({ metadatadb => $parameters->{metadatadb}, node => $parameters->{metadata} });
        my @mdIds = ();
        foreach my $md ( $results->get_nodelist ) {
            my $tmpMdId = $md->getAttribute( "id" );
            $tmpMdId =~ s/meta//;
            push @mdIds,  $tmpMdId;
        }
        $dataResults = $self->sqLiteCreateKeyData({ metadatadb => $parameters->{metadatadb}, metaDataIds => \@mdIds });
    }else{
        if ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "file" ) {
            $queryString = "/nmwg:store/nmwg:metadata[" . getMetadataXQuery( { node => $parameters->{metadata} } ) . "]";
        }
    
        $self->{LOGGER}->debug( "Running query \"" . $queryString . "\"" );
    
        my $results             = $parameters->{metadatadb}->querySet( { query => $queryString } );
        my %et                  = ();
        my $eventTypes          = find( $parameters->{metadata}, "./nmwg:eventType", 0 );
        my $supportedEventTypes = find( $parameters->{metadata}, ".//nmwg:parameter[\@name=\"supportedEventType\" or \@name=\"eventType\"]", 0 );
        foreach my $e ( $eventTypes->get_nodelist ) {
            my $value = extract( $e, 0 );
            if ( $value ) {
                $et{$value} = 1;
            }
        }
        foreach my $se ( $supportedEventTypes->get_nodelist ) {
            my $value = extract( $se, 0 );
            if ( $value ) {
                $et{$value} = 1;
            }
        }
    
        if ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "file" ) {
            $queryString = "/nmwg:store/nmwg:data";
        }
    
        if ( $eventTypes->size() or $supportedEventTypes->size() ) {
            $queryString = $queryString . "[./nmwg:key/nmwg:parameters/nmwg:parameter[(\@name=\"supportedEventType\" or \@name=\"eventType\")";
            foreach my $e ( sort keys %et ) {
                $queryString = $queryString . " and (\@value=\"" . $e . "\" or text()=\"" . $e . "\")";
            }
            $queryString = $queryString . "]]";
        }
        
        $self->{LOGGER}->debug( "Running query \"" . $queryString . "\"" );
        
        my $dataResults = $parameters->{metadatadb}->querySet( { query => $queryString } );
    }
    
    if ( $results->size() > 0 and $dataResults->size() > 0 ) {
        my %mds = ();
        foreach my $md ( $results->get_nodelist ) {
            my $curr_md_id = $md->getAttribute( "id" );
            next if not $curr_md_id;
            $mds{$curr_md_id} = $md;
        }

        foreach my $d ( $dataResults->get_nodelist ) {
            my $curr_d_mdIdRef = $d->getAttribute( "metadataIdRef" );
            next if ( not $curr_d_mdIdRef or not exists $mds{$curr_d_mdIdRef} );
            my $curr_md = $mds{$curr_d_mdIdRef};

            # XXX jz 1/26/09
            # For now if the store file already contains the first/last time info we are
            #  going to return it as is.  We need to check to be sure this hasn't been
            #  updated by something external (e.g. cricket)

            my $done = extract( find( $d, ".//nmwg:parameter[\@name=\"firstTime\"]", 1 ), 1 );
            if ( $done ) {
                $parameters->{output}->addExistingXMLElement( $curr_md );
                $parameters->{output}->addExistingXMLElement( $d );
            }
            else {
                my $dId  = "data." . genuid();
                my $mdId = "metadata." . genuid();

                my $md_temp = $curr_md->cloneNode( 1 );
                $md_temp->setAttribute( "metadataIdRef", $curr_d_mdIdRef );
                $md_temp->setAttribute( "id",            $mdId );

                my $hashId  = $d->getAttribute( "id" );
                my $hashKey = $self->{ID_TO_HASH}->{$hashId};

                next if ( not defined $hashKey );

                my $key2 = $d->cloneNode( 1 );
                my $params = find( $key2, ".//nmwg:parameters", 1 );

                my $rrd_file = extract( find( $params, ".//nmwg:parameter[\@name=\"file\"]", 1 ), 1 );
                my $rrd = new perfSONAR_PS::DB::RRD( { path => $self->{CONF}->{"snmp"}->{"rrdtool"}, name => $rrd_file, error => 1 } );
                $rrd->openDB;
                my $first = $rrd->firstValue();
                my $last  = $rrd->lastValue();

                if ( $rrd->getErrorMessage ) {
                    my $msg = "Data storage error";
                    $self->{LOGGER}->error( $msg );
                    throw perfSONAR_PS::Error_compat( "error.ma.storage_result", $msg );
                }
                else {
                    $parameters->{output}->addExistingXMLElement( $md_temp );

                    my $thing = XML::LibXML::Element->new( "parameter" );
                    $thing->setNamespace( "http://ggf.org/ns/nmwg/base/2.0/", "nmwg", 1 );
                    $thing->setAttribute( "name", "firstTime" );
                    $thing->appendTextNode( $first );
                    $params->addChild( $thing );
                    $thing = XML::LibXML::Element->new( "parameter" );
                    $thing->setNamespace( "http://ggf.org/ns/nmwg/base/2.0/", "nmwg", 1 );
                    $thing->setAttribute( "name", "lastTime" );
                    $thing->appendTextNode( $last );
                    $params->addChild( $thing );
                    $thing = XML::LibXML::Element->new( "parameter" );
                    $thing->setNamespace( "http://ggf.org/ns/nmwg/base/2.0/", "nmwg", 1 );
                    $thing->setAttribute( "name", "maKey" );
                    $thing->appendTextNode( $hashKey );
                    $params->addChild( $thing );

                    $self->addSelectParameters( { parameter_block => $params, filters => $parameters->{filters} } );
                    createData( $parameters->{output}, $dId, $mdId, $key2->toString, undef );
                }
                $rrd->closeDB;
            }
        }
    }
    else {
        my $msg = "Database \"" . $self->{CONF}->{"snmp"}->{"metadata_db_file"} . "\" returned 0 results for search";
        $self->{LOGGER}->error( $msg );
        throw perfSONAR_PS::Error_compat( "error.ma.storage", $msg );
    }
    return;
}

=head2 maSetupDataRequest($self, $output, $md, $request, $message_parameters)

Main handler of SetupDataRequest messages.  Based on contents (i.e. was a
key sent in the request, or not) this will route to one of two functions:

 - setupDataRetrieveKey          - Handles all requests that enter with a 
                                   key present.  
 - setupDataRetrieveMetadataData - Handles all other requests
 
Chaining operations are handled internally, although chaining will eventually
be moved to the overall message handler as it is an important operation that
all services will need.

The goal of this message type is to return actual data, so after the metadata
section is resolved the appropriate data handler will be called to interact
with the database of choice (i.e. rrdtool, mysql, sqlite).  

=cut

sub maSetupDataRequest {
    my ( $self, @args ) = @_;
    my $parameters = validateParams(
        @args,
        {
            output             => 1,
            metadata           => 1,
            filters            => 1,
            time_settings      => 1,
            request            => 1,
            message_parameters => 1
        }
    );
    my $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.SetupDataRequest.start" );
    $self->{NETLOGGER}->debug( $msg );

    my $mdId  = q{};
    my $dId   = q{};
    my $error = q{};
    if ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "sqlite" ) {
        $self->{METADATADB} = $self->prepareSQLiteDatabases();
        unless ( $self->{METADATADB} ) {
            throw perfSONAR_PS::Error_compat( "SQLite database could not be opened." );
            return;
        }
    }elsif ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} ne "file" ) {
        throw perfSONAR_PS::Error_compat( "Wrong value for 'metadata_db_type' set." );
        return;
    }

    my $nmwg_key = find( $parameters->{metadata}, "./nmwg:key", 1 );
    if ( $nmwg_key ) {
        $self->{LOGGER}->info( "Key found - running SetupDataRequest with existing key." );
        $self->setupDataRetrieveKey(
            {
                metadatadb         => $self->{METADATADB},
                metadata           => $nmwg_key,
                filters            => $parameters->{filters},
                message_parameters => $parameters->{message_parameters},
                time_settings      => $parameters->{time_settings},
                request_namespaces => $parameters->{request}->getNamespaces(),
                output             => $parameters->{output}
            }
        );
    }
    else {
        $self->{LOGGER}->info( "Key found - running SetupDataRequest with existing key." );
        $self->setupDataRetrieveMetadataData(
            {
                metadatadb         => $self->{METADATADB},
                metadata           => $parameters->{metadata},
                filters            => $parameters->{filters},
                time_settings      => $parameters->{time_settings},
                message_parameters => $parameters->{message_parameters},
                output             => $parameters->{output}
            }
        );
    }
    
    $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.SetupDataRequest.end" );
    $self->{NETLOGGER}->debug( $msg );
    return;
}

=head2 setupDataRetrieveKey($self, $metadatadb, $metadata, $chain, $id,
                            $message_parameters, $request_namespaces, $output)

Because the request entered with a key, we must handle it in this particular
function.  We first attempt to extract the 'maKey' hash and check for validity.
An invalid or missing key will trigger an error instantly.  If the key is found
we see if any chaining needs to be done.  We finally call the handle data
function, passing along the useful pieces of information from the metadata
database to locate and interact with the backend storage (i.e. rrdtool, mysql, 
sqlite).  

=cut

sub setupDataRetrieveKey {
    my ( $self, @args ) = @_;
    my $parameters = validateParams(
        @args,
        {
            metadatadb         => 1,
            metadata           => 1,
            filters            => 1,
            time_settings      => 1,
            message_parameters => 1,
            request_namespaces => 1,
            output             => 1
        }
    );

    my $mdId    = q{};
    my $dId     = q{};
    my $results = q{};

    my $hashKey = extract( find( $parameters->{metadata}, ".//nmwg:parameter[\@name=\"maKey\"]", 1 ), 0 );
    unless ( $hashKey ) {
        my $msg = "Key error in metadata storage - key format is incorrect.";
        $self->{LOGGER}->error( $msg );
        throw perfSONAR_PS::Error_compat( "error.ma.storage_result", $msg );
        return;
    }

    my $hashId = $self->{HASH_TO_ID}->{$hashKey};
    unless ( $hashId ) {
        my $msg = "Key error in metadata storage - key not found.";
        $self->{LOGGER}->error( $msg );
        throw perfSONAR_PS::Error_compat( "error.ma.storage_result", $msg );
        return;
    }

    $self->{LOGGER}->debug( "Received hash key $hashKey which maps to $hashId" );

    my $query = q{};
    if ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "file" ) {
        $query = "/nmwg:store/nmwg:data[\@id=\"" . $hashId . "\"]";
        $self->{LOGGER}->debug( "Running query \"" . $query . "\"" );
        $results = $parameters->{metadatadb}->querySet( { query => $query } );
    }
    elsif( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "sqlite" ){
        $results = $self->sqLiteCreateKeyData( { metadatadb => $parameters->{metadatadb}, keyId => "$hashId" } );
    }

    if ( $results->size() != 1 ) {
        my $msg = "Key error in metadata storage - key not found in database.";
        $self->{LOGGER}->error( $msg );
        throw perfSONAR_PS::Error_compat( "error.ma.storage_result", $msg );
        return;
    }

    my $sentKey      = $parameters->{metadata}->cloneNode( 1 );
    my $results_temp = $results->get_node( 1 )->cloneNode( 1 );
    my $storedKey    = find( $results_temp, "./nmwg:key", 1 );

    my %l_et = ();
    my $l_supportedEventTypes = find( $storedKey, ".//nmwg:parameter[\@name=\"supportedEventType\" or \@name=\"eventType\"]", 0 );
    foreach my $se ( $l_supportedEventTypes->get_nodelist ) {
        my $value = extract( $se, 0 );
        if ( $value ) {
            $l_et{$value} = 1;
        }
    }

    $mdId = "metadata." . genuid();
    $dId  = "data." . genuid();

    my $mdIdRef = $parameters->{metadata}->getAttribute( "id" );

    my @filters = @{ $parameters->{filters} };

    if ( $#filters > -1 ) {
        $self->addSelectParameters( { parameter_block => find( $sentKey, ".//nmwg:parameters", 1 ), filters => \@filters } );

        $mdIdRef = $filters[-1][0]->getAttribute( "id" );
    }

    createMetadata( $parameters->{output}, $mdId, $mdIdRef, $sentKey->toString, undef );
    $self->handleData(
        {
            id                 => $mdId,
            data               => $results_temp,
            output             => $parameters->{output},
            time_settings      => $parameters->{time_settings},
            et                 => \%l_et,
            message_parameters => $parameters->{message_parameters}
        }
    );

    return;
}

=head2 setupDataRetrieveMetadataData($self, $metadatadb, $metadata, $id, 
                                     $message_parameters, $output)

Similar to 'setupDataRetrieveKey' we are looking to return data.  The input
will be partially or fully specified metadata.  If this matches something in
the database we will return a data matching the description.  If this metadata
was a part of a chain the chaining will be resolved passed along to the data
handling function.

=cut

sub setupDataRetrieveMetadataData {
    my ( $self, @args ) = @_;
    my $parameters = validateParams(
        @args,
        {
            metadatadb         => 1,
            metadata           => 1,
            filters            => 1,
            time_settings      => 1,
            message_parameters => 1,
            output             => 1
        }
    );

    my $mdId = q{};
    my $dId  = q{};
    my $results     = q{};
    my $dataResults = q{};
    my $msg  = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.setupDataRetrieveMetadataData.start" );
    $self->{NETLOGGER}->debug( $msg );

    my $queryString = q{};
    if ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "file" ) {
        $queryString = "/nmwg:store/nmwg:metadata[" . getMetadataXQuery( { node => $parameters->{metadata} } ) . "]";
    }

    if ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "sqlite" ){
        $results = $self->sqLiteCreateMetadata({ metadatadb => $parameters->{metadatadb}, node => $parameters->{metadata} });
        my @mdIds = ();
        foreach my $md ( $results->get_nodelist ) {
            my $tmpMdId = $md->getAttribute( "id" );
            $tmpMdId =~ s/meta//;
            push @mdIds,  $tmpMdId;
        }
        $dataResults = $self->sqLiteCreateKeyData({ metadatadb => $parameters->{metadatadb}, metaDataIds => \@mdIds });
    } 
    else {
        $self->{LOGGER}->debug( "Running query \"" . $queryString . "\"" );
        $results = $parameters->{metadatadb}->querySet( { query => $queryString } );
        
        my %et                  = ();
        my $eventTypes          = find( $parameters->{metadata}, "./nmwg:eventType", 0 );
        my $supportedEventTypes = find( $parameters->{metadata}, ".//nmwg:parameter[\@name=\"supportedEventType\" or \@name=\"eventType\"]", 0 );
        foreach my $e ( $eventTypes->get_nodelist ) {
            my $value = extract( $e, 0 );
            if ( $value ) {
                $et{$value} = 1;
            }
        }
        foreach my $se ( $supportedEventTypes->get_nodelist ) {
            my $value = extract( $se, 0 );
            if ( $value ) {
                $et{$value} = 1;
            }
        }
    
        if ( $self->{CONF}->{"snmp"}->{"metadata_db_type"} eq "file" ) {
            $queryString = "/nmwg:store/nmwg:data";
        }
    
        if ( $eventTypes->size() or $supportedEventTypes->size() ) {
            $queryString = $queryString . "[./nmwg:key/nmwg:parameters/nmwg:parameter[(\@name=\"supportedEventType\" or \@name=\"eventType\")";
            foreach my $e ( sort keys %et ) {
                $queryString = $queryString . " and (\@value=\"" . $e . "\" or text()=\"" . $e . "\")";
            }
            $queryString = $queryString . "]]";
        }
        
        $self->{LOGGER}->debug( "Running query \"" . $queryString . "\"" );
        $dataResults = $parameters->{metadatadb}->querySet( { query => $queryString } );
    }
    
    my %used = ();
    for my $x ( 0 .. $dataResults->size() ) {
        $used{$x} = 0;
    }

    my $base_id = $parameters->{metadata}->getAttribute( "id" );
    my @filters = @{ $parameters->{filters} };
    if ( $#filters > -1 ) {
        my @filter_arr = @{ $filters[-1] };

        $base_id = $filter_arr[0]->getAttribute( "id" );
    }

    if ( $results->size() > 0 and $dataResults->size() > 0 ) {
        my %mds = ();
        foreach my $md ( $results->get_nodelist ) {
            next if not $md->getAttribute( "id" );

            my %l_et                  = ();
            my $l_eventTypes          = find( $md, "./nmwg:eventType", 0 );
            my $l_supportedEventTypes = find( $md, ".//nmwg:parameter[\@name=\"supportedEventType\" or \@name=\"eventType\"]", 0 );
            foreach my $e ( $l_eventTypes->get_nodelist ) {
                my $value = extract( $e, 0 );
                if ( $value ) {
                    $l_et{$value} = 1;
                }
            }
            foreach my $se ( $l_supportedEventTypes->get_nodelist ) {
                my $value = extract( $se, 0 );
                if ( $value ) {
                    $l_et{$value} = 1;
                }
            }

            my %hash = ();
            $hash{"md"}                       = $md;
            $hash{"et"}                       = \%l_et;
            $mds{ $md->getAttribute( "id" ) } = \%hash;
        }

        foreach my $d ( $dataResults->get_nodelist ) {
            my $idRef = $d->getAttribute( "metadataIdRef" );

            next if ( not defined $idRef or not defined $mds{$idRef} );

            my $md_temp = $mds{$idRef}->{"md"}->cloneNode( 1 );
            my $d_temp  = $d->cloneNode( 1 );
            $mdId = "metadata." . genuid();
            $md_temp->setAttribute( "metadataIdRef", $base_id );
            $md_temp->setAttribute( "id",            $mdId );
            $parameters->{output}->addExistingXMLElement( $md_temp );
            $self->handleData(
                {
                    id                 => $mdId,
                    data               => $d_temp,
                    output             => $parameters->{output},
                    time_settings      => $parameters->{time_settings},
                    et                 => $mds{$idRef}->{"et"},
                    message_parameters => $parameters->{message_parameters}
                }
            );
        }
    }
    else {
        my $msg = "Database \"" . $self->{CONF}->{"snmp"}->{"metadata_db_file"} . "\" returned 0 results for search";
        $self->{LOGGER}->error( $msg );
        throw perfSONAR_PS::Error_compat( "error.ma.storage", $msg );
    }
    $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.setupDataRetrieveMetadataData.end" );
    $self->{NETLOGGER}->debug( $msg );
    return;
}

=head2 handleData($self, $id, $data, $output, $et, $message_parameters)

Directs the data retrieval operations based on a value found in the metadata
database's representation of the key (i.e. storage 'type').  Current offerings
only interact with rrd files and sql databases.

=cut

sub handleData {
    my ( $self, @args ) = @_;
    my $parameters = validateParams(
        @args,
        {
            id                 => 1,
            data               => 1,
            output             => 1,
            et                 => 1,
            time_settings      => 1,
            message_parameters => 1
        }
    );

    my $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.handleData.start" );
    $self->{NETLOGGER}->debug( $msg );

    my $type = extract( find( $parameters->{data}, "./nmwg:key/nmwg:parameters/nmwg:parameter[\@name=\"type\"]", 1 ), 0 );

    if ( $type eq "rrd" ) {
        $self->{LOGGER}->info( "Handling RRD type data." );
        $self->retrieveRRD(
            {
                d                  => $parameters->{data},
                mid                => $parameters->{id},
                output             => $parameters->{output},
                time_settings      => $parameters->{time_settings},
                et                 => $parameters->{et},
                message_parameters => $parameters->{et}
            }

        );
    }
    elsif ( $type eq "sqlite" ) {
        $self->{LOGGER}->info( "Handling SQL type data." );
        $self->retrieveSQL(

            {
                d                  => $parameters->{data},
                mid                => $parameters->{id},
                output             => $parameters->{output},
                time_settings      => $parameters->{time_settings},
                et                 => $parameters->{et},
                message_parameters => $parameters->{et}
            }
        );
    }
    elsif ( $type eq "esxsnmp" ) {
        $self->retrieveESxSNMP(

            {    
                d                  => $parameters->{data},
                mid                => $parameters->{id},
                output             => $parameters->{output},
                time_settings      => $parameters->{time_settings},
                et                 => $parameters->{et},
                message_parameters => $parameters->{et}
            }    
        );   
    }    
    else {
        my $msg = "Database \"" . $type . "\" is not yet supported";
        $self->{LOGGER}->error( $msg );
        getResultCodeData( $parameters->{output}, "data." . genuid(), $parameters->{id}, $msg, 1 );
    }
    $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.handleData.end" );
    $self->{NETLOGGER}->debug( $msg );
    return;
}

=head2 retrieveSQL($self, $d, $mid, $output, $et, $message_parameters)

Given some 'startup' knowledge such as the name of the database and any
credentials to connect with it, we start a connection and query the database
for given values.  These values are prepared into XML response content and
return in the response message.

=cut

sub retrieveSQL {
    my ( $self, @args ) = @_;
    my $parameters = validateParams(
        @args,
        {
            d                  => 1,
            mid                => 1,
            time_settings      => 1,
            output             => 1,
            et                 => 1,
            message_parameters => 1
        }
    );

    my $datumns  = 0;
    my $timeType = q{};

    if ( defined $parameters->{message_parameters}->{"eventNameSpaceSynchronization"}
        and lc( $parameters->{message_parameters}->{"eventNameSpaceSynchronization"} ) eq "true" )
    {
        $datumns = 1;
    }

    if ( defined $parameters->{message_parameters}->{"timeType"} ) {
        if ( lc( $parameters->{message_parameters}->{"timeType"} ) eq "unix" ) {
            $timeType = "unix";
        }
        elsif ( lc( $parameters->{message_parameters}->{"timeType"} ) eq "iso" ) {
            $timeType = "iso";
        }
    }

    $self->{LOGGER}->error( "No data element" ) unless ( defined $parameters->{d} );

    my $file   = extract( find( $parameters->{d}, "./nmwg:key//nmwg:parameter[\@name=\"file\"]",  1 ), 1 );
    my $table  = extract( find( $parameters->{d}, "./nmwg:key//nmwg:parameter[\@name=\"table\"]", 1 ), 1 );
    my $dbuser = extract( find( $parameters->{d}, "./nmwg:key//nmwg:parameter[\@name=\"user\"]",  1 ), 1 );
    my $dbpass = extract( find( $parameters->{d}, "./nmwg:key//nmwg:parameter[\@name=\"pass\"]",  1 ), 1 );

    unless ( $file and $table ) {
        $self->{LOGGER}->error( "Data element " . $parameters->{d}->getAttribute( "id" ) . " is missing some SQL elements" );
        throw perfSONAR_PS::Error_compat( "error.ma.storage", "Unable to open associated database" );
    }

    my $backup = $file;
    if ( $backup =~ m/^DBI:SQLite:dbname=/mx ) {
        $backup =~ s/^DBI:SQLite:dbname=//mx;
    }
    if ( exists $self->{DIRECTORY} and $self->{DIRECTORY} and -d $self->{DIRECTORY} ) {
        if ( !( $backup =~ "^/" ) ) {
            $backup = $self->{DIRECTORY} . "/" . $backup;
        }
    }
    $file = "dbi:SQLite:dbname=" . $backup;

    my $query = {};
    if ( $parameters->{time_settings}->{"START"}->{"internal"} or $parameters->{time_settings}->{"END"}->{"internal"} ) {
        $query = "select * from " . $table . " where id=\"" . $parameters->{d}->getAttribute( "metadataIdRef" ) . "\" and";
        my $queryCount = 0;
        if ( $parameters->{time_settings}->{"START"}->{"internal"} ) {
            $query = $query . " time > " . $parameters->{time_settings}->{"START"}->{"internal"};
            $queryCount++;
        }
        if ( $parameters->{time_settings}->{"END"}->{"internal"} ) {
            if ( $queryCount ) {
                $query = $query . " and time < " . $parameters->{time_settings}->{"END"}->{"internal"} . ";";
            }
            else {
                $query = $query . " time < " . $parameters->{time_settings}->{"END"}->{"internal"} . ";";
            }
        }
    }
    else {
        $query = "select * from " . $table . " where id=\"" . $parameters->{d}->getAttribute( "metadataIdRef" ) . "\";";
    }

    $self->{LOGGER}->info( "Query to database is \"" . $query . "\"" );

    my @dbSchema = ( "id", "time", "value", "eventtype", "misc" );
    my $datadb = new perfSONAR_PS::DB::SQL( { name => $file, schema => \@dbSchema, user => $dbuser, pass => $dbpass } );

    $datadb->openDB;
    my $result = $datadb->query( { query => $query } );
    $datadb->closeDB;

    my $id = "data." . genuid();
    if ( $#{$result} == -1 ) {
        my $msg = "Query returned 0 results";
        $self->{LOGGER}->error( $msg );
        getResultCodeData( $parameters->{output}, $id, $parameters->{mid}, $msg, 1 );
    }
    else {
        my $prefix = "nmwg";
        my $uri    = "http://ggf.org/ns/nmwg/base/2.0/";

        if ( $datumns ) {
            if ( defined $parameters->{et} and $parameters->{et} ne q{} ) {
                foreach my $e ( sort keys %{ $parameters->{et} } ) {
                    next if $e eq "http://ggf.org/ns/nmwg/tools/snmp/2.0/";
                    $uri = $e;
                }
            }
            if ( $uri ne "http://ggf.org/ns/nmwg/base/2.0" ) {
                foreach my $r ( sort keys %{ $self->{NAMESPACES} } ) {
                    if ( ( $uri . "/" ) eq $self->{NAMESPACES}->{$r} ) {
                        $prefix = $r;
                        last;
                    }
                }
                if ( !$prefix ) {
                    $prefix = "nmwg";
                    $uri    = "http://ggf.org/ns/nmwg/base/2.0/";
                }
            }
        }

        startData( $parameters->{output}, $id, $parameters->{mid}, undef );
        my $len = $#{$result};
        for my $a ( 0 .. $len ) {
            my %attrs = ();
            if ( $timeType eq "iso" ) {
                my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) = gmtime( $result->[$a][1] );
                $attrs{"timeType"} = "ISO";
                $attrs{ $dbSchema[1] . "Value" } = sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ\n", ( $year + 1900 ), ( $mon + 1 ), $mday, $hour, $min, $sec;
            }
            else {
                $attrs{"timeType"} = "unix";
                $attrs{ $dbSchema[1] . "Value" } = $result->[$a][1];
            }
            $attrs{ $dbSchema[2] } = $result->[$a][2];

            my @misc = split( /,/xm, $result->[$a][4] );
            foreach my $m ( @misc ) {
                my @pair = split( /=/xm, $m );
                $attrs{ $pair[0] } = $pair[1];
            }

            $parameters->{output}->createElement(
                prefix     => $prefix,
                namespace  => $uri,
                tag        => "datum",
                attributes => \%attrs
            );
        }
        endData( $parameters->{output} );
    }
    return;
}

=head2 retrieveRRD($self, $d, $mid, $output, $et, $message_parameters)

Given some 'startup' knowledge such as the name of the database and any
credentials to connect with it, we start a connection and query the database
for given values.  These values are prepared into XML response content and
return in the response message.

=cut

sub retrieveRRD {
    my ( $self, @args ) = @_;
    my $parameters = validateParams(
        @args,
        {
            d                  => 1,
            mid                => 1,
            time_settings      => 1,
            output             => 1,
            et                 => 1,
            message_parameters => 1
        }
    );

    my $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.retrieveRRD.setup.start" );
    $self->{NETLOGGER}->debug( $msg );

    my $timeSettings = $parameters->{time_settings};

    my ( $sec, $frac ) = Time::HiRes::gettimeofday;
    my $datumns  = 0;
    my $timeType = q{};

    if ( defined $parameters->{message_parameters}->{"eventNameSpaceSynchronization"}
        and lc( $parameters->{message_parameters}->{"eventNameSpaceSynchronization"} ) eq "true" )
    {
        $datumns = 1;
    }

    if ( defined $parameters->{message_parameters}->{"timeType"} ) {
        if ( lc( $parameters->{message_parameters}->{"timeType"} ) eq "unix" ) {
            $timeType = "unix";
        }
        elsif ( lc( $parameters->{message_parameters}->{"timeType"} ) eq "iso" ) {
            $timeType = "iso";
        }
    }

    my $file_element = find( $parameters->{d}, "./nmwg:key//nmwg:parameter[\@name=\"file\"]", 1 );

    my $rrd_file = extract( $file_element, 1 );

    if ( not $rrd_file ) {
        $self->{LOGGER}->error( "Data element " . $parameters->{d}->getAttribute( "id" ) . " is missing some RRD file" );
        throw perfSONAR_PS::Error_compat( "error.ma.storage", "Unable to open associated RRD file" );
    }

    adjustRRDTime( { timeSettings => $timeSettings } );
    my $id = "data." . genuid();

    $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.retrieveRRD.setup.end" );
    $self->{NETLOGGER}->debug( $msg );

    $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.getDataRRD.start", { rrdfile => $rrd_file, } );
    $self->{NETLOGGER}->debug( $msg );

    my %rrd_result = $self->getDataRRD( { directory => $self->{DIRECTORY}, file => $rrd_file, timeSettings => $timeSettings, rrdtool => $self->{CONF}->{"snmp"}->{"rrdtool"} } );

    $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.getDataRRD.end" );
    $self->{NETLOGGER}->debug( $msg );

    if ( $rrd_result{ERROR} ) {
        $self->{LOGGER}->error( "RRD error seen: " . $rrd_result{ERROR} );
        getResultCodeData( $parameters->{output}, $id, $parameters->{mid}, $rrd_result{ERROR}, 1 );
    }
    else {
        my $prefix = "nmwg";
        my $uri    = "http://ggf.org/ns/nmwg/base/2.0/";
        if ( $datumns ) {
            if ( defined $parameters->{et} and $parameters->{et} ne q{} ) {
                foreach my $e ( sort keys %{ $parameters->{et} } ) {
                    next if $e eq "http://ggf.org/ns/nmwg/tools/snmp/2.0/";
                    $uri = $e;
                }
            }
            if ( $uri ne "http://ggf.org/ns/nmwg/base/2.0" ) {
                foreach my $r ( sort keys %{ $self->{NAMESPACES} } ) {
                    if ( ( $uri . "/" ) eq $self->{NAMESPACES}->{$r} ) {
                        $prefix = $r;
                        last;
                    }
                }
                if ( !$prefix ) {
                    $prefix = "nmwg";
                    $uri    = "http://ggf.org/ns/nmwg/base/2.0/";
                }
            }
        }

        my $dataSource = extract( find( $parameters->{d}, "./nmwg:key//nmwg:parameter[\@name=\"dataSource\"]", 1 ), 0 );
        my $valueUnits = extract( find( $parameters->{d}, "./nmwg:key//nmwg:parameter[\@name=\"valueUnits\"]", 1 ), 0 );

        startData( $parameters->{output}, $id, $parameters->{mid}, undef );
        $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.retrieveRRD.genXML.start" );
        $self->{NETLOGGER}->debug( $msg );
        foreach my $a ( sort( keys( %rrd_result ) ) ) {
            if ( $a < $sec ) {
                my %attrs = ();
                if ( $timeType eq "iso" ) {
                    my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) = gmtime( $a );
                    $attrs{"timeType"} = "ISO";
                    $attrs{"timeValue"} = sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ\n", ( $year + 1900 ), ( $mon + 1 ), $mday, $hour, $min, $sec;
                }
                else {
                    $attrs{"timeType"}  = "unix";
                    $attrs{"timeValue"} = $a;
                }
                $attrs{"value"}      = $rrd_result{$a}{$dataSource};
                $attrs{"valueUnits"} = $valueUnits;

                $parameters->{output}->createElement(
                    prefix     => $prefix,
                    namespace  => $uri,
                    tag        => "datum",
                    attributes => \%attrs
                );
            }
        }
        endData( $parameters->{output} );
        $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.retrieveRRD.genXML.end" );
        $self->{NETLOGGER}->debug( $msg );
    }
    return;
}

=head2 retrieveESxSNMP($self, $d, $mid, $output, $et, $message_parameters)

Given some 'startup' knowledge such as the name of the database and any
credentials to connect with it, we start a connection and query the database
for given values.  These values are prepared into XML response content and
return in the response message.

=cut

sub retrieveESxSNMP {
    my ( $self, @args ) = @_;
    my $parameters = validateParams(
        @args,
        {
            d                  => 1,
            mid                => 1,
            time_settings      => 1,
            output             => 1,
            et                 => 1,
            message_parameters => 1
        }
    );

    my $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.retrieveESxSNMP.setup.start" );
    $self->{NETLOGGER}->debug( $msg );

    my $timeSettings = $parameters->{time_settings};

    my ( $sec, $frac ) = Time::HiRes::gettimeofday;
    my $datumns  = 0;
    my $timeType = q{};

    if ( defined $parameters->{message_parameters}->{"eventNameSpaceSynchronization"}
        and lc( $parameters->{message_parameters}->{"eventNameSpaceSynchronization"} ) eq "true" )
    {
        $datumns = 1;
    }

    if ( defined $parameters->{message_parameters}->{"timeType"} ) {
        if ( lc( $parameters->{message_parameters}->{"timeType"} ) eq "unix" ) {
            $timeType = "unix";
        }
        elsif ( lc( $parameters->{message_parameters}->{"timeType"} ) eq "iso" ) {
            $timeType = "iso";
        }
    }

    my $name = extract( find( $parameters->{d}, "./nmwg:key//nmwg:parameter[\@name=\"name\"]",  1 ), 1 );

    unless ( $name ) {
        $self->{LOGGER}->error( "Data element " .  $parameters->{d}->getAttribute( "id" ) . " name not specified" );
        throw perfSONAR_PS::Error_compat( "error.ma.storage", "Unable to open associated database" );
    }

    my $id = "data." . genuid();

    $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.retrieveESxSNMP.setup.end" );
    $self->{NETLOGGER}->debug( $msg );

    $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.getDataESxSNMP.start", { name => $name, } );
    $self->{NETLOGGER}->debug( $msg );

    my $cf = $timeSettings->{"CF"};
    my $start = $timeSettings->{"START"}->{"internal"};
    my $end = $timeSettings->{"END"}->{"internal"};
    my $resolution = $timeSettings->{"RESOLUTION"};
    my $datadb = new perfSONAR_PS::DB::ESxSNMP( { server_url => $self->{CONF}->{"snmp"}->{esxsnmp_server} } );
    $datadb->openDB();

    my $result = $datadb->query( { name => $name, resolution => $resolution, cf => $cf, start => $start, end => $end } );
    $datadb->closeDB();

    $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.getDataESxSNMP.end" );
    $self->{NETLOGGER}->debug( $msg );

    if ( !$result ) {
        $self->{LOGGER}->error( "ESxSNMP error: unable to retrieve data" );
        throw perfSONAR_PS::Error_compat( "error.ma.storage", "Unable to retrieve SNMP data from ESxSNMP" );
    }
    else {
        my $prefix = "nmwg";
        my $uri    = "http://ggf.org/ns/nmwg/base/2.0/";
        if ( $datumns ) {
            if ( defined $parameters->{et} and $parameters->{et} ne q{} ) {
                foreach my $e ( sort keys %{ $parameters->{et} } ) {
                    next if $e eq "http://ggf.org/ns/nmwg/tools/snmp/2.0/";
                    $uri = $e;
                }
            }
            if ( $uri ne "http://ggf.org/ns/nmwg/base/2.0" ) {
                foreach my $r ( sort keys %{ $self->{NAMESPACES} } ) {
                    if ( ( $uri . "/" ) eq $self->{NAMESPACES}->{$r} ) {
                        $prefix = $r;
                        last;
                    }
                }
                if ( !$prefix ) {
                    $prefix = "nmwg";
                    $uri    = "http://ggf.org/ns/nmwg/base/2.0/";
                }
            }
        }

        my $dataSource = extract( find( $parameters->{d}, "./nmwg:key//nmwg:parameter[\@name=\"dataSource\"]", 1 ), 0 );
        my $valueUnits = extract( find( $parameters->{d}, "./nmwg:key//nmwg:parameter[\@name=\"valueUnits\"]", 1 ), 0 );

        startData( $parameters->{output}, $id, $parameters->{mid}, undef );
        $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.retrieveRRD.genXML.start" );
        $self->{NETLOGGER}->debug( $msg );
        foreach my $a ( 0 .. $#{$result} ) {
            if ( $a < $sec ) {
                my ($ts, $val) = @{$result->[$a]};
                my %attrs = ();
                if ( $timeType eq "iso" ) {
                    my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) = gmtime( $ts );
                    $attrs{"timeType"} = "ISO";
                    $attrs{"timeValue"} = sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ\n", ( $year + 1900 ), ( $mon + 1 ), $mday, $hour, $min, $sec;
                }
                else {
                    $attrs{"timeType"}  = "unix";
                    $attrs{"timeValue"} = $ts;
                }
                $attrs{"value"}      = $val;
                $attrs{"valueUnits"} = $valueUnits;

                $parameters->{output}->createElement(
                    prefix     => $prefix,
                    namespace  => $uri,
                    tag        => "datum",
                    attributes => \%attrs
                );
            }
        }
        endData( $parameters->{output} );
        $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.retrieveRRD.genXML.end" );
        $self->{NETLOGGER}->debug( $msg );
    }
    return;
}
=head2 addSelectParameters($self, { parameter_block, filters })

Re-construct the parameters block.

=cut

sub addSelectParameters {
    my ( $self, @args ) = @_;
    my $parameters = validateParams(
        @args,
        {
            parameter_block => 1,
            filters         => 1,
        }
    );

    my $params       = $parameters->{parameter_block};
    my @filters      = @{ $parameters->{filters} };
    my %paramsByName = ();

    foreach my $p ( $params->childNodes ) {
        if ( $p->localname and $p->localname eq "parameter" and $p->getAttribute( "name" ) ) {
            $paramsByName{ $p->getAttribute( "name" ) } = $p;
        }
    }

    foreach my $filter_arr ( @filters ) {
        my @filters = @{$filter_arr};
        my $filter  = $filters[-1];

        $self->{LOGGER}->debug( "Filter: " . $filter->toString );

        my $select_params = find( $filter, "./select:parameters", 1 );
        if ( $select_params ) {
            foreach my $p ( $select_params->childNodes ) {
                if ( $p->localname and $p->localname eq "parameter" and $p->getAttribute( "name" ) ) {
                    my $newChild = $p->cloneNode( 1 );
                    if ( $paramsByName{ $p->getAttribute( "name" ) } ) {
                        $params->replaceChild( $newChild, $paramsByName{ $p->getAttribute( "name" ) } );
                    }
                    else {
                        $params->addChild( $newChild );
                    }
                    $paramsByName{ $p->getAttribute( "name" ) } = $newChild;
                }
            }
        }
    }
    return;
}

=head2 getDataRRD( $self, { directory, file, timeSettings, rrdtool } )

Returns either an error or the actual results of an RRD database query.

=cut

sub getDataRRD {
    my ( $self, @args ) = @_;
    my $parameters = validateParams(
        @args,
        {
            directory    => 1,
            file         => 1,
            timeSettings => 1,
            rrdtool      => 1
        }
    );
    my $logger = get_logger( "perfSONAR_PS::Services::MA::General" );

    my %result = ();
    if ( exists $parameters->{directory} and $parameters->{directory} ) {
        unless ( $parameters->{file} =~ "^/" ) {
            $parameters->{file} = $parameters->{directory} . "/" . $parameters->{file};
        }
    }

    my $datadb = new perfSONAR_PS::DB::RRD( { path => $parameters->{rrdtool}, name => $parameters->{file}, error => 1 } );
    $datadb->openDB;

    if (
        not $parameters->{timeSettings}->{"CF"}
        or (    $parameters->{timeSettings}->{"CF"} ne "AVERAGE"
            and $parameters->{timeSettings}->{"CF"} ne "MIN"
            and $parameters->{timeSettings}->{"CF"} ne "MAX"
            and $parameters->{timeSettings}->{"CF"} ne "LAST" )
        )
    {
        $parameters->{timeSettings}->{"CF"} = "AVERAGE";
    }

    my %rrd_result = $datadb->query(
        {
            cf         => $parameters->{timeSettings}->{"CF"},
            resolution => $parameters->{timeSettings}->{"RESOLUTION"},
            start      => $parameters->{timeSettings}->{"START"}->{"internal"},
            end        => $parameters->{timeSettings}->{"END"}->{"internal"}
        }
    );

    if ( $datadb->getErrorMessage ) {
        my $msg = "Query error \"" . $datadb->getErrorMessage . "\"; query returned \"" . $rrd_result{ANSWER} . "\"";
        $logger->error( $msg );
        $result{"ERROR"} = $msg;
        $datadb->closeDB;
        return %result;
    }
    else {
        $datadb->closeDB;
        return %rrd_result;
    }
}

=head2 sqLiteCreateMetadata( $self, { metadatadb, node } )

Generates metadata from sqlite database. Accepts a perfSONAR_PS::DB::SQL database handle as a 
required parameter. Also optionally accepts a "node" which is a metadata LibXml node from the 
request that it uses to filter the metadata returned. 

=cut
sub sqLiteCreateMetadata {
    my ( $self, @args ) = @_;
    my $parameters = validateParams(@args, { metadatadb => 1, node => 0 });
    my @resultsString = ();
    
    my $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.sqLiteCreateMetadata.start" );
    $self->{NETLOGGER}->debug( $msg );
    
    #build a map to grab the prexies of the namespaces
    my %nsPrefixMap = ();
    foreach my $prefix( keys %ma_namespaces ){
        $nsPrefixMap{$ma_namespaces{$prefix}} = $prefix;
    }
    
    #map of database fields in interface table
    my %xfaceDbFields = ( 'urn' => 'urn',
                     'hostName' => 'hostName',
                     'ifName' => 'ifName',
                     'ifDescription' => 'ifDescription',
                     'ifAddress' => 'ifAddress',
                     'capacity' => 'capacity',
                     'direction' => 'direction',
                     'authRealm' => 'authRealm',
                   );
                
    #Build where
    my $where = q{};
    if ( $parameters->{node} && $parameters->{node}->getType != 8 && $parameters->{node}->hasChildNodes()) {
        foreach my $c ( $parameters->{node}->childNodes ) {
            if($c->nodeName =~ /(\w+:)?subject/ && $c->hasChildNodes()){
                foreach my $sc ( $c->childNodes ) {
                    if($sc->nodeName =~ /(\w+:)?interface/ && $sc->hasChildNodes()){
                        foreach my $ic ( $sc->childNodes ) {
                            my $elem_name = $ic->nodeName;
                            $elem_name =~ s/^\w+://;
                            if($ic->textContent && exists $xfaceDbFields{$elem_name}){
                                $where .= ' AND ' if( $where );
                                $where .= 'i.' . $xfaceDbFields{$elem_name} . "='" . $ic->textContent . "'";
                            }
                        }
                    }
                }
            }elsif($c->nodeName =~ /(\w+:)?eventType/ && $c->textContent){
                my $namespace = $c->textContent;
                $namespace .= '/' if(exists $nsPrefixMap{$namespace.'/'});
                $where .= ' AND ' if( $where );
                $where .= ' (m.eventType = "' . $namespace . '" OR "' . $namespace . '" IN (SELECT value FROM metadataParams WHERE key="supportedEventType" AND metadataId=m.id))';
            }
        }
    }
    $where = ' WHERE ' . $where if($where);
    
    #get metadata
    my $result = $parameters->{'metadatadb'}->query({
            query => "SELECT m.id, i.urn, i.hostName, i.ifName, i.ifAddress, i.ifDescription, i.capacity, i.direction, i.authRealm, m.eventType FROM metadata AS m INNER JOIN interfaces AS i ON m.interfaceId = i.id" . $where
        });
    if($result == -1){
        $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.sqLiteCreateMetadata.end", { status => -1 } );
        $self->{NETLOGGER}->error( $msg );
        return -1;
    }
     
    #get parameters
    my $param_where = q{};
    if($where){ #only constrain params if metadata constrained
        my $first = 1;
        $param_where = ' WHERE metadataId IN (';
        foreach my $md( @{$result} ){ 
            $param_where .= ',' if($first != 1);
            $param_where .= $md->[0];
            $first = 0;
        }
        $param_where .= ')';
    }
    
    my $paramResults = $parameters->{'metadatadb'}->query({
        query => "SELECT metadataId, key, value FROM metadataParams" . $param_where
    });
    if($paramResults == -1){
        $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.sqLiteCreateMetadata.end", { status => -1 } );
        $self->{NETLOGGER}->error( $msg );
        return -1;
    }
    
    my %param_map = ();
    foreach my $pr(@{$paramResults}){
        if(! exists $param_map{$pr->[0]} ){
            my @tmpArr =();
            $param_map{$pr->[0]} = \@tmpArr;
        }
        my @tmpParam = ($pr->[1], $pr->[2]);
        push @{ $param_map{$pr->[0]} }, \@tmpParam;
    }
    
    #loop through metatdata and grab parameters
    my $xml_doc = XML::LibXML->createDocument;
    my $node_list = new XML::LibXML::NodeList;
    foreach my $md( @{$result} ){   
        my $namespace = $md->[9];
        $namespace .= '/' if(exists $nsPrefixMap{$namespace.'/'});
        
        my $md_elem = $xml_doc->createElementNS('http://ggf.org/ns/nmwg/base/2.0/', 'nmwg:metadata');
        $md_elem->setAttributeNode($xml_doc->createAttribute('id', 'meta' . $md->[0]));
        
        my $subj_elem =  $xml_doc->createElementNS($namespace, $nsPrefixMap{$namespace} . ':subject');
        $subj_elem->setAttributeNode($xml_doc->createAttribute('id', 'subj' . $md->[0]));
        $md_elem->addChild($subj_elem);
        
        my $xface_elem = $xml_doc->createElementNS('http://ggf.org/ns/nmwg/topology/2.0/', 'nmwgt:interface');
        $subj_elem->addChild($xface_elem);
        
        if($md->[1]){
            my $urn = $xml_doc->createElementNS('http://ggf.org/ns/nmwg/topology/base/3.0/', 'nmwgt3:urn');
            $urn->appendTextNode( $md->[1] );
            $xface_elem->addChild($urn);
        }
        
        if($md->[2]){
            my $hostname = $xml_doc->createElementNS('http://ggf.org/ns/nmwg/topology/2.0/', 'nmwgt:hostName');
            $hostname->appendTextNode( $md->[2] );
            $xface_elem->addChild($hostname);
        }
        
        if($md->[3]){
            my $ifname = $xml_doc->createElementNS('http://ggf.org/ns/nmwg/topology/2.0/', 'nmwgt:ifName');
            $ifname->appendTextNode( $md->[3] );
            $xface_elem->addChild($ifname);
        }
        
        if($md->[4]){
            my $ifname = $xml_doc->createElementNS('http://ggf.org/ns/nmwg/topology/2.0/', 'nmwgt:ifAddress');
            $ifname->appendTextNode( $md->[4] );
            $xface_elem->addChild($ifname);
        }
        
        if($md->[5]){
            my $ifdescr = $xml_doc->createElementNS('http://ggf.org/ns/nmwg/topology/2.0/', 'nmwgt:ifDescription');
            $ifdescr->appendTextNode( $md->[5] );
            $xface_elem->addChild($ifdescr);
        }
        
        if($md->[6]){
            my $capacity = $xml_doc->createElementNS('http://ggf.org/ns/nmwg/topology/2.0/', 'nmwgt:capacity');
            $capacity->appendTextNode( $md->[6] );
            $xface_elem->addChild($capacity);
        }
        
        if($md->[7]){
            my $direction = $xml_doc->createElementNS('http://ggf.org/ns/nmwg/topology/2.0/', 'nmwgt:direction');
            $direction->appendTextNode( $md->[7] );
            $xface_elem->addChild($direction);
        }
        
        if($md->[8]){
            my $authRealm = $xml_doc->createElementNS('http://ggf.org/ns/nmwg/topology/2.0/', 'nmwgt:authRealm');
            $authRealm->appendTextNode( $md->[8] );
            $xface_elem->addChild($authRealm);
        }
        
        my $eventType = $xml_doc->createElementNS('http://ggf.org/ns/nmwg/base/2.0/', 'nmwg:eventType');
        $eventType->appendTextNode( $namespace );
        $md_elem->addChild($eventType);
		
		my $params_elem = $xml_doc->createElementNS('http://ggf.org/ns/nmwg/base/2.0/', 'nmwg:parameters');
		$params_elem->setAttributeNode($xml_doc->createAttribute('id', 'metaparam' . $md->[0]));
		$md_elem->addChild($params_elem);
        
        if(exists $param_map{$md->[0]}){
            foreach my $param(@{$param_map{$md->[0]}}){
                my $param_elem = $xml_doc->createElementNS('http://ggf.org/ns/nmwg/base/2.0/', 'nmwg:parameter');
                $param_elem->setAttributeNode($xml_doc->createAttribute('name', $param->[0]));
                $param_elem->appendTextNode( $param->[1] );
                $params_elem->addChild($param_elem);
            }
        }
        
        $node_list->push( $md_elem );
    }
    
    $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.sqLiteCreateMetadata.end" );
    $self->{NETLOGGER}->debug( $msg );
    
    return $node_list;
}

=head2 sqLiteCreateKeyData( $self, { metadatadb, keyId, metaDataIds } )

Generates the elements used to calculate the maKey and are also used by data backend to find data.
Accepts a perfSONAR_PS::DB::SQL database handle as a required parameter. Also optionally accepts a 
keyId which identifies the specific key to get. Alternatively it accepts a metaDataIds as an array
of metaDataIds that much match for the key to be returned.

=cut
sub sqLiteCreateKeyData {
    my ( $self, @args ) = @_;
    my $parameters = validateParams(@args, { metadatadb => 1, keyId => 0, metaDataIds => 0 });
    my @resultsString = ();
    
    my $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.sqLiteCreateKeyData.start" );
    $self->{NETLOGGER}->debug( $msg );
    
    my $where = q{};
    if($parameters->{'keyId'} && $parameters->{'metaDataIds'}){
        #can't provide both
        $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.sqLiteCreateKeyData.end", { status => -1 } );
        $self->{NETLOGGER}->error( $msg );
        return -1;
    }elsif($parameters->{'keyId'}){
        my $tmpId = $parameters->{'keyId'};
        $tmpId =~ s/data//;
        $where = " WHERE id=$tmpId";
    }elsif($parameters->{'metaDataIds'} && ref($parameters->{'metaDataIds'}) eq 'ARRAY'){
        $where = " WHERE metaDataId IN (" .  (join ',', @{$parameters->{'metaDataIds'}}) . ")";
    }
    
    
    #get the metadata
    my $result = $parameters->{'metadatadb'}->query({
            query => "SELECT id, metadataId, type, name, valueUnits, eventType FROM dataKeys" . $where
        });
    if($result == -1){
        $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.sqLiteCreateKeyData.end", { status => -1 } );
        $self->{NETLOGGER}->error( $msg );
        return -1;
    }
    
    #build a map to grab the prexies of the namespaces
    my %nsPrefixMap = ();
    foreach my $prefix( keys %ma_namespaces ){
        $nsPrefixMap{$ma_namespaces{$prefix}} = $prefix;
    }
    
    #loop through metatdata and grab parameters
    my $xml_doc = XML::LibXML->createDocument;
    my $node_list = new XML::LibXML::NodeList;
    foreach my $d( @{$result} ){
        my $data_elem = $xml_doc->createElementNS('http://ggf.org/ns/nmwg/base/2.0/', 'nmwg:data');
        $data_elem->setAttributeNode($xml_doc->createAttribute('id', 'data' . $d->[0]));
        $data_elem->setAttributeNode($xml_doc->createAttribute('metadataIdRef', 'meta' . $d->[1]));
        
        my $key_elem = $xml_doc->createElementNS('http://ggf.org/ns/nmwg/base/2.0/', 'nmwg:key');
        $key_elem->setAttributeNode($xml_doc->createAttribute('id', 'keyid' . $d->[0]));
        $data_elem->addChild($key_elem);
        
        my $params_elem = $xml_doc->createElementNS('http://ggf.org/ns/nmwg/base/2.0/', 'nmwg:parameters');
        $params_elem->setAttributeNode($xml_doc->createAttribute('id', 'dataparam' . $d->[0]));
        $key_elem->addChild($params_elem);
        
        my $paramType = $xml_doc->createElementNS('http://ggf.org/ns/nmwg/base/2.0/', 'nmwg:parameter');
        $paramType->setAttributeNode($xml_doc->createAttribute('name', 'type'));
        $paramType->appendTextNode( $d->[2] );
        $params_elem->addChild($paramType);
        
        my $paramName = $xml_doc->createElementNS('http://ggf.org/ns/nmwg/base/2.0/', 'nmwg:parameter');
        $paramName->setAttributeNode($xml_doc->createAttribute('name', 'name'));
        $paramName->appendTextNode( $d->[3] );
        $params_elem->addChild($paramName);
        
        my $paramUnits = $xml_doc->createElementNS('http://ggf.org/ns/nmwg/base/2.0/', 'nmwg:parameter');
        $paramUnits->setAttributeNode($xml_doc->createAttribute('name', 'valueUnits'));
        $paramUnits->appendTextNode( $d->[4] );
        $params_elem->addChild($paramUnits);
        
        my $paramEventType = $xml_doc->createElementNS('http://ggf.org/ns/nmwg/base/2.0/', 'nmwg:parameter');
        $paramEventType->setAttributeNode($xml_doc->createAttribute('name', 'eventType'));
        $paramEventType->appendTextNode( $d->[5] );
        $params_elem->addChild($paramEventType);
        
        $node_list->push( $data_elem );
    }
    
    $msg = perfSONAR_PS::Utils::NetLogger::format( "org.perfSONAR.Services.MA.sqLiteCreateKeyData.end" );
    $self->{NETLOGGER}->debug( $msg );
    
    return $node_list;
}
1;

__END__

=head1 SEE ALSO

L<Log::Log4perl>, L<Module::Load>, L<Digest::MD5>, L<English>, 
L<Params::Validate>, L<Date::Manip>, L<perfSONAR_PS::Services::MA::General>,
L<perfSONAR_PS::Common>, L<perfSONAR_PS::Messages>,
L<perfSONAR_PS::Client::LS::Remote>, L<perfSONAR_PS::Error_compat>,
L<perfSONAR_PS::DB::File>, L<perfSONAR_PS::DB::RRD>, L<perfSONAR_PS::DB::SQL>, 
L<perfSONAR_PS::Utils::ParameterValidation>, L<perfSONAR_PS::Utils::NetLogger>

To join the 'perfSONAR-PS Users' mailing list, please visit:

  https://lists.internet2.edu/sympa/info/perfsonar-ps-users

The perfSONAR-PS subversion repository is located at:

  http://anonsvn.internet2.edu/svn/perfSONAR-PS/trunk

Questions and comments can be directed to the author, or the mailing list.
Bugs, feature requests, and improvements can be directed here:

  http://code.google.com/p/perfsonar-ps/issues/list

=head1 VERSION

$Id$

=head1 AUTHOR

Jason Zurawski, zurawski@internet2.edu
Aaron Brown, aaron@internet2.edu
Guilherme Fernandes, fernande@cis.udel.edu

=head1 LICENSE

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=head1 COPYRIGHT

Copyright (c) 2007-2010, Internet2 and the University of Delaware

All rights reserved.

=cut
