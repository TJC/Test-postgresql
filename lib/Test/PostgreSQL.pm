package Test::PostgreSQL;

use strict;
use warnings;

use 5.008;
use Class::Accessor::Lite;
use Cwd;
use DBI;
use File::Temp qw(tempdir);
use Time::HiRes qw(nanosleep);
use POSIX qw(SIGTERM SIGKILL WNOHANG setuid);

our $VERSION = '1.05';

# Various paths that Postgres gets installed under, sometimes with a version on the end,
# in which case take the highest version. We append /bin/ and so forth to the path later.
# Note that these are used only if the program isn't already in the path.
our @SEARCH_PATHS = (
    split(/:/, $ENV{PATH}),
    # popular installation dir?
    qw(/usr/local/pgsql),
    # ubuntu (maybe debian as well, find the newest version)
    (sort { $b cmp $a } grep { -d $_ } glob "/usr/lib/postgresql/*"),
    # macport
    (sort { $b cmp $a } grep { -d $_ } glob "/opt/local/lib/postgresql-*"),
    # Postgresapp.com
    (sort { $b cmp $a } grep { -d $_ } glob "/Applications/Postgres.app/Contents/Versions/*"),
    # BSDs end up with it in /usr/local/bin which doesn't appear to be in the path sometimes:
    "/usr/local",
);

# This environment variable is used to override the default, so it gets
# prefixed to the start of the search paths.
if (defined $ENV{POSTGRES_HOME} and -d $ENV{POSTGRES_HOME}) {
    unshift @SEARCH_PATHS, $ENV{POSTGRES_HOME};
}

our $errstr;
our $BASE_PORT = 15432;

our %Defaults = (
    auto_start      => 2,
    base_dir        => undef,
    initdb          => undef,
    initdb_args     => '-U postgres -A trust',
    pid             => undef,
    port            => undef,
    postmaster      => undef,
    postmaster_args => '-h 127.0.0.1',
    uid             => undef,
    _owner_pid      => undef,
);

Class::Accessor::Lite->mk_accessors(keys %Defaults);

sub new {
    my $klass = shift;
    my $self = bless {
        %Defaults,
        @_ == 1 ? %{$_[0]} : @_,
        _owner_pid => $$,
    }, $klass;
    if (! defined $self->uid && $ENV{USER} eq 'root') {
        my @a = getpwnam('nobody')
            or die "user nobody does not exist, use uid() to specify user:$!";
        $self->uid($a[2]);
    }
    if (defined $self->base_dir) {
        $self->base_dir(cwd . '/' . $self->base_dir)
            if $self->base_dir !~ m|^/|;
    } else {
        $self->base_dir(
            tempdir(
                CLEANUP => $ENV{TEST_POSTGRESQL_PRESERVE} ? undef : 1,
            ),
        );
        chown $self->uid, -1, $self->base_dir
            if defined $self->uid;
    }
    if (! defined $self->initdb) {
        my $prog = _find_program('initdb')
            or return;
        $self->initdb($prog);
    }
    if (! defined $self->postmaster) {
        my $prog = _find_program('postmaster')
            or return;
        $self->postmaster($prog);
    }
    if ($self->auto_start) {
        $self->setup
            if $self->auto_start >= 2;
        $self->start;
    }
    $self;
}

sub DESTROY {
    my $self = shift;
    $self->stop
        if defined $self->pid && $$ == $self->_owner_pid;
    return;
}

sub dsn {
    my ($self, %args) = @_;
    $args{host} ||= '127.0.0.1';
    $args{port} ||= $self->port;
    $args{user} ||= 'postgres';
    $args{dbname} ||= 'test';
    return 'DBI:Pg:' . join(';', map { "$_=$args{$_}" } sort keys %args);
}

sub uri {
    my ($self, %args) = @_;
    return sprintf('postgresql://postgres@127.0.0.1:%d/test', $self->port);
}

sub start {
    my $self = shift;
    return
        if defined $self->pid;
    # start (or die)
    sub {
        my $err;
        if ($self->port) {
            $err = $self->_try_start($self->port)
                or return;
        } else {
            # try by incrementing port no
            for (my $port = $BASE_PORT; $port < $BASE_PORT + 100; $port++) {
                $err = $self->_try_start($port)
                    or return;
            }
        }
        # failed
        die "failed to launch PostgreSQL:$!\n$err";
    }->();
    { # create "test" database
        my $tries = 5;
        my $dbh;
        while ($tries) {
            $tries -= 1;
            $dbh = DBI->connect($self->dsn(dbname => 'template1'), '', '', {
                PrintError => 0,
                RaiseError => 0
            });
            last if $dbh;

            # waiting for database to start up
            if ($DBI::errstr =~ /the database system is starting up/ 
                || $DBI::errstr =~ /Connection refused/) {
                sleep(1);
                next;
            }
            die $DBI::errstr;
        }

        die "Connection to the database failed even after 5 tries"
            unless ($dbh);

        if ($dbh->selectrow_arrayref(q{SELECT COUNT(*) FROM pg_database WHERE datname='test'})->[0] == 0) {
            $dbh->do('CREATE DATABASE test')
                or die $dbh->errstr;
        }
    }
}

sub _try_start {
    my ($self, $port) = @_;
    # open log and fork
    open my $logfh, '>>', $self->base_dir . '/postgres.log'
        or die 'failed to create log file:' . $self->base_dir
            . "/postgres.log:$!";
    my $pid = fork;
    die "fork(2) failed:$!"
        unless defined $pid;
    if ($pid == 0) {
        open STDOUT, '>>&', $logfh
            or die "dup(2) failed:$!";
        open STDERR, '>>&', $logfh
            or die "dup(2) failed:$!";
        chdir $self->base_dir
            or die "failed to chdir to:" . $self->base_dir . ":$!";
        if (defined $self->uid) {
            setuid($self->uid)
                or die "setuid failed:$!";
        }
        my $cmd = join(
            ' ',
            $self->postmaster,
            $self->postmaster_args,
            '-p', $port,
            '-D', $self->base_dir . '/data',
            '-k', $self->base_dir . '/tmp',
        );
        exec($cmd);
        die "failed to launch postmaster:$?";
    }
    close $logfh;
    # wait until server becomes ready (or dies)
    for (my $i = 0; $i < 100; $i++) {
        open $logfh, '<', $self->base_dir . '/postgres.log'
            or die 'failed to open log file:' . $self->base_dir
                . "/postgres.log:$!";
        my $lines = do { join '', <$logfh> };
        close $logfh;
        last
            if $lines =~ /is ready to accept connections/;
        if (waitpid($pid, WNOHANG) > 0) {
            # failed
            return $lines;
        }
        sleep 1;
    }
    # PostgreSQL is ready
    $self->pid($pid);
    $self->port($port);
    return;
}

sub stop {
    my ($self, $sig) = @_;
    return unless defined $self->pid;

    $sig ||= SIGTERM;

    kill $sig, $self->pid;
    my $timeout = 10 * 1000000000;
    while ($timeout > 0 and waitpid($self->pid, WNOHANG) <= 0) {
        $timeout -= nanosleep(500000000);
    }

    if ($timeout <= 0) {
        warn "Pg refused to die gracefully; killing it violently.\n";
        kill SIGKILL, $self->pid;
        $timeout = 5 * 1000000000;
        while ($timeout > 0 and waitpid($self->pid, WNOHANG) <= 0) {
            $timeout -= nanosleep(500000000);
        }
        if ($timeout <= 0) {
            warn "Pg really didn't die.. WTF?\n";
        }
    }

    $self->pid(undef);
    return;
}

sub setup {
    my $self = shift;
    # (re)create directory structure
    mkdir $self->base_dir;
    chmod 0755, $self->base_dir
        or die "failed to chmod 0755 dir:" . $self->base_dir . ":$!";
    if ($ENV{USER} eq 'root') {
        chown $self->uid, -1, $self->base_dir
            or die "failed to chown dir:" . $self->base_dir . ":$!";
    }
    if (mkdir $self->base_dir . '/tmp') {
        if ($self->uid) {
            chown $self->uid, -1, $self->base_dir . '/tmp'
                or die "failed to chown dir:" . $self->base_dir . "/tmp:$!";
        }
    }
    # initdb
    if (! -d $self->base_dir . '/data') {
        pipe my $rfh, my $wfh
            or die "failed to create pipe:$!";
        my $pid = fork;
        die "fork failed:$!"
            unless defined $pid;
        if ($pid == 0) {
            close $rfh;
            open STDOUT, '>&', $wfh
                or die "dup(2) failed:$!";
            open STDERR, '>&', $wfh
                or die "dup(2) failed:$!";
            chdir $self->base_dir
                or die "failed to chdir to:" . $self->base_dir . ":$!";
            if (defined $self->uid) {
                setuid($self->uid)
                    or die "setuid failed:$!";
            }
            my $cmd = join(
                ' ',
                $self->initdb,
                $self->initdb_args,
                '-D', $self->base_dir . '/data',
            );
            exec($cmd);
            die "failed to exec:$cmd:$!";
        }
        close $wfh;
        my $output = '';
        while (my $l = <$rfh>) {
            $output .= $l;
        }
        close $rfh;
        while (waitpid($pid, 0) <= 0) {
        }
        die "*** initdb failed ***\n$output\n"
            if $? != 0;

        # use postgres hard-coded configuration as some packagers mess
        # around with postgresql.conf.sample too much:
        truncate $self->base_dir . '/data/postgresql.conf', 0;
    }
}

sub _find_program {
    my $prog = shift;
    undef $errstr;
    for my $sp (@SEARCH_PATHS) {
        return "$sp/bin/$prog" if -x "$sp/bin/$prog";
        return "$sp/$prog" if -x "$sp/$prog";
    }
    $errstr = "could not find $prog, please set appropriate PATH or POSTGRES_HOME";
    return;
}

1;
__END__

=pod

=encoding utf8

=head1 NAME

Test::PostgreSQL - PostgreSQL runner for tests

=head1 SYNOPSIS

  use DBI;
  use Test::PostgreSQL;
  use Test::More;

  # optionally
  # (if not already set at shell):
  #
  # $ENV{POSTGRES_HOME} = '/path/to/my/pgsql/installation';

  my $pgsql = Test::PostgreSQL->new()
      or plan skip_all => $Test::PostgreSQL::errstr;

  plan tests => XXX;

  my $dbh = DBI->connect($pgsql->dsn);

=head1 DESCRIPTION

C<Test::PostgreSQL> automatically setups a PostgreSQL instance in a temporary
directory, and destroys it when the perl script exits.

This module is a fork of Test::postgresql, which was abandoned by its author
several years ago.

=head1 FUNCTIONS

=head2 new

Create and run a PostgreSQL instance.  The instance is terminated when the
returned object is being DESTROYed.  If required programs (initdb and
postmaster) were not found, the function returns undef and sets appropriate
message to $Test::PostgreSQL::errstr.

=head2 base_dir

Returns directory under which the PostgreSQL instance is being created.  The
property can be set as a parameter of the C<new> function, in which case the
directory will not be removed at exit.

=head2 initdb

=head2 postmaster

Path to C<initdb> and C<postmaster> which are part of the PostgreSQL
distribution.  If not set, the programs are automatically searched by looking
up $PATH and other prefixed directories.

=head2 initdb_args

=head2 postmaster_args

Arguments passed to C<initdb> and C<postmaster>.  Following example adds
--encoding=utf8 option to C<initdb_args>.

  my $pgsql = Test::PostgreSQL->new(
      initdb_args
          => $Test::PostgreSQL::Defaults{initdb_args} . ' --encoding=utf8'
  ) or plan skip_all => $Test::PostgreSQL::errstr;

=head2 dsn

Builds and returns dsn by using given parameters (if any).  Default username is
'postgres', and dbname is 'test' (an empty database).

=head2 pid

Returns process id of PostgreSQL (or undef if not running).

=head2 port

Returns TCP port number on which postmaster is accepting connections (or undef
if not running).

=head2 start

Starts postmaster.

=head2 stop

Stops postmaster.

=head2 setup

Setups the PostgreSQL instance.

=head1 ENVIRONMENT

=head2 POSTGRES_HOME

If your postgres installation is not located in a well known path, or you have
many versions installed and want to run your tests against particular one, set
this environment variable to the desired path. For example:

 export POSTGRES_HOME='/usr/local/pgsql94beta'

This is the same idea and variable name which is used by the installer of
L<DBD::Pg>.

=head1 AUTHOR

Toby Corkindale, Kazuho Oku, and various contributors.

=head1 COPYRIGHT

Current version copyright © 2012-2014 Toby Corkindale.

Previous versions copyright (C) 2009 Cybozu Labs, Inc.

=head1 LICENSE

This module is free software, released under the Perl Artistic License 2.0.
See L<http://www.perlfoundation.org/artistic_license_2_0> for more information.

=cut
