use Test::More tests => 4;

use strict;
use warnings;

use File::Spec;
use Test::PostgreSQL;

my $pg = Test::PostgreSQL->new();

ok defined($pg), "test instance 1 created";

my $conf_file = File::Spec->catfile(
    $pg->base_dir, 'data', 'postgresql.conf'
);

# By default postgresql.conf is truncated
is -s $conf_file, 0, "test 1 postgresql.conf size 0";

undef $pg;

$pg = Test::PostgreSQL->new(
    pg_config => <<'EOC',
# foo baroo mymse throbbozongo
fsync = off
synchronous_commit = off
full_page_writes = off
bgwriter_lru_maxpages = 0
shared_buffers = 512MB
effective_cache_size = 512MB
work_mem = 100MB
EOC
);

ok defined($pg), "test instance 2 created";

$conf_file = File::Spec->catfile(
    $pg->base_dir, 'data', 'postgresql.conf'
);

open my $fh, '<', $conf_file;
my $pg_conf = <$fh>;
close $fh;

like $pg_conf, qr/foo baroo mymse throbbozongo/,
    "test instance 2 postgresql.conf match";
