package DBIx::Class::DeploymentHandler;

use Moose;
use Method::Signatures::Simple;
require DBIx::Class::Schema;    # loaded for type constraint
require DBIx::Class::Storage;   # loaded for type constraint
require DBIx::Class::ResultSet; # loaded for type constraint
use Carp::Clan '^DBIx::Class::DeploymentHandler';

has schema => (
  isa      => 'DBIx::Class::Schema',
  is       => 'ro',
  required => 1,
  handles => [qw( ddl_filename schema_version )],
);

has upgrade_directory => (
  isa      => 'Str',
  is       => 'ro',
  required => 1,
  default  => 'sql',
);

has backup_directory => (
  isa => 'Str',
  is  => 'ro',
);

has storage => (
  isa        => 'DBIx::Class::Storage',
  is         => 'ro',
  lazy_build => 1,
);

method _build_storage {
  my $s = $self->schema->storage;
  $s->_determine_driver;
  $s
}

has _filedata => (
  isa => 'ArrayRef[Str]',
  is  => 'rw',
);

has do_backup => (
  isa     => 'Bool',
  is      => 'ro',
  default => undef,
);

has do_diff_on_init => (
  isa     => 'Bool',
  is      => 'ro',
  default => undef,
);

has version_rs => (
  isa        => 'DBIx::Class::ResultSet',
  is         => 'ro',
  lazy_build => 1,
  handles    => [qw( is_installed db_version )],
);

method _build_version_rs {
   $self->schema->set_us_up_the_bomb;
   $self->schema->resultset('__VERSION')
}

method backup { $self->storage->backup($self->backup_directory) }

method install($new_version) {
  carp 'Install not possible as versions table already exists in database'
    if $self->is_installed;

  $new_version ||= $self->schema_version;

  if ($new_version) {
    $self->schema->deploy;

    $self->version_rs->create({
      version     => $new_version,
      # ddl         => $ddl,
      # upgrade_sql => $upgrade_sql,
    });
  }
}

method create_upgrade_path { }

method ordered_schema_versions { undef }

method upgrade {
  my $db_version     = $self->db_version;
  my $schema_version = $self->schema_version;

  unless ($db_version) {
    # croak?
    carp 'Upgrade not possible as database is unversioned. Please call install first.';
    return;
  }

  if ( $db_version eq $schema_version ) {
    # croak?
    carp "Upgrade not necessary\n";
    return;
  }

  my @version_list = $self->ordered_schema_versions ||
    ( $db_version, $schema_version );

  # remove all versions in list above the required version
  while ( @version_list && ( $version_list[-1] ne $schema_version ) ) {
    pop @version_list;
  }

  # remove all versions in list below the current version
  while ( @version_list && ( $version_list[0] ne $db_version ) ) {
    shift @version_list;
  }

  # check we have an appropriate list of versions
  die if @version_list < 2;

  # do sets of upgrade
  while ( @version_list >= 2 ) {
    $self->upgrade_single_step( $version_list[0], $version_list[1] );
    shift @version_list;
  }
}

method upgrade_single_step($db_version, $target_version) {
  if ($db_version eq $target_version) {
    # croak?
    carp "Upgrade not necessary\n";
    return;
  }

  my $upgrade_file = $self->ddl_filename(
    $self->storage->sqlt_type,
    $target_version,
    $self->upgrade_directory,
    $db_version,
  );

  $self->create_upgrade_path({ upgrade_file => $upgrade_file });

  unless (-f $upgrade_file) {
    # croak?
    carp "Upgrade not possible, no upgrade file found ($upgrade_file), please create one\n";
    return;
  }

  carp "DB version ($db_version) is lower than the schema version (".$self->schema_version."). Attempting upgrade.\n";

  $self->_filedata($self->_read_sql_file($upgrade_file)); # I don't like this --fREW 2010-02-22
  $self->backup if $self->do_backup;
  $self->schema->txn_do(sub { $self->do_upgrade });

  $self->version_rs->create({
    version     => $target_version,
    # ddl         => $ddl,
    # upgrade_sql => $upgrade_sql,
  });
}

method create_ddl_dir($databases, $version, $dir, $preversion, $sqltargs) {
  my $schema = $self->schema;
  if(!$dir || !-d $dir) {
    carp "No directory given, using ./\n";
    $dir = "./";
  }
  $databases ||= ['MySQL', 'SQLite', 'PostgreSQL'];
  $databases = [ $databases ] if(ref($databases) ne 'ARRAY');

  my $schema_version = $schema->schema_version || '1.x';
  $version ||= $schema_version;

  $sqltargs = {
    add_drop_table => 1,
    ignore_constraint_names => 1,
    ignore_index_names => 1,
    %{$sqltargs || {}}
  };

  unless (DBIx::Class::Optional::Dependencies->req_ok_for ('deploy')) {
    $self->throw_exception("Can't create a ddl file without " . DBIx::Class::Optional::Dependencies->req_missing_for ('deploy') );
  }

  my $sqlt = SQL::Translator->new( $sqltargs );

  $sqlt->parser('SQL::Translator::Parser::DBIx::Class');
  my $sqlt_schema = $sqlt->translate({ data => $schema })
    or $self->throw_exception ($sqlt->error);

  foreach my $db (@$databases) {
    $sqlt->reset();
    $sqlt->{schema} = $sqlt_schema;
    $sqlt->producer($db);

    my $file;
    my $filename = $schema->ddl_filename($db, $version, $dir);
    if (-e $filename && ($version eq $schema_version )) {
      # if we are dumping the current version, overwrite the DDL
      carp "Overwriting existing DDL file - $filename";
      unlink($filename);
    }

    my $output = $sqlt->translate;
    if(!$output) {
      carp("Failed to translate to $db, skipping. (" . $sqlt->error . ")");
      next;
    }
    if(!open($file, ">$filename")) {
      $self->throw_exception("Can't open $filename for writing ($!)");
      next;
    }
    print $file $output;
    close($file);

    next unless ($preversion);

    require SQL::Translator::Diff;

    my $prefilename = $schema->ddl_filename($db, $preversion, $dir);
    if(!-e $prefilename) {
      carp("No previous schema file found ($prefilename)");
      next;
    }

    my $difffile = $schema->ddl_filename($db, $version, $dir, $preversion);
    if(-e $difffile) {
      carp("Overwriting existing diff file - $difffile");
      unlink($difffile);
    }

    my $source_schema;
    {
      my $t = SQL::Translator->new($sqltargs);
      $t->debug( 0 );
      $t->trace( 0 );

      $t->parser( $db )
        or $self->throw_exception ($t->error);

      my $out = $t->translate( $prefilename )
        or $self->throw_exception ($t->error);

      $source_schema = $t->schema;

      $source_schema->name( $prefilename )
        unless ( $source_schema->name );
    }

    # The "new" style of producers have sane normalization and can support
    # diffing a SQL file against a DBIC->SQLT schema. Old style ones don't
    # And we have to diff parsed SQL against parsed SQL.
    my $dest_schema = $sqlt_schema;

    unless ( "SQL::Translator::Producer::$db"->can('preprocess_schema') ) {
      my $t = SQL::Translator->new($sqltargs);
      $t->debug( 0 );
      $t->trace( 0 );

      $t->parser( $db )
        or $self->throw_exception ($t->error);

      my $out = $t->translate( $filename )
        or $self->throw_exception ($t->error);

      $dest_schema = $t->schema;

      $dest_schema->name( $filename )
        unless $dest_schema->name;
    }

    my $diff = SQL::Translator::Diff::schema_diff($source_schema, $db,
                                                  $dest_schema,   $db,
                                                  $sqltargs
                                                 );
    if(!open $file, ">$difffile") {
      $self->throw_exception("Can't write to $difffile ($!)");
      next;
    }
    print $file $diff;
    close($file);
  }
}

method do_upgrade { $self->run_upgrade(qr/.*?/) }

method run_upgrade($stm) {
  return unless $self->_filedata;
  my @statements = grep { $_ =~ $stm } @{$self->_filedata};

  for (@statements) {
    $self->storage->debugobj->query_start($_) if $self->storage->debug;
    $self->apply_statement($_);
    $self->storage->debugobj->query_end($_) if $self->storage->debug;
  }
}

method apply_statement($statement) {
  # croak?
  $self->storage->dbh->do($_) or carp "SQL was: $_"
}

method _read_sql_file($file) {
  return unless $file;

  open my $fh, '<', $file or carp("Can't open upgrade file, $file ($!)");
  my @data = split /\n/, join '', <$fh>;
  close $fh;

  @data = grep {
    $_ &&
    !/^--/ &&
    !/^(BEGIN|BEGIN TRANSACTION|COMMIT)/m
  } split /;/,
    join '', @data;

  return \@data;
}

1;

__END__

vim: ts=2,sw=2,expandtab
