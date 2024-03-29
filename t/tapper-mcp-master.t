#!/usr/bin/env perl

use strict;
use warnings;
use 5.010;

# get rid of warnings
use Class::C3;
use MRO::Compat;
use Log::Log4perl;
use Test::Fixture::DBIC::Schema;
use Test::MockModule;

use Tapper::Model 'model';
use Tapper::Schema::TestTools;

use Tapper::MCP::Master;
use File::Temp;

use Test::More;
use Test::Deep;

BEGIN { use_ok('Tapper::MCP::Master'); }

# -----------------------------------------------------------------------------------------------------------------
construct_fixture( schema  => testrundb_schema, fixture => 't/fixtures/testrundb/testrun_with_scheduling.yml' );
# -----------------------------------------------------------------------------------------------------------------

my $mockmaster = Test::MockModule->new('Tapper::MCP::Master');
$mockmaster->mock('console_open',sub{use IO::Socket::INET;
                                     my $sock = IO::Socket::INET->new(Listen=>0);
                                     return $sock;});
$mockmaster->mock('console_close',sub{return "mocked console_close";});

my $mockchild = Test::MockModule->new('Tapper::MCP::Child');
$mockchild->mock('runtest_handling',sub{my $self = shift @_; $self->rerun(1);return 0;});

my $mockschedule = Test::MockModule->new('Tapper::MCP::Scheduler::Controller');
$mockschedule->mock('get_next_testrun',sub{return('bullock',4)});


my $master   = Tapper::MCP::Master->new();
my $retval;

isa_ok($master, 'Tapper::MCP::Master');

$retval = $master->console_open();
isa_ok($retval, 'IO::Socket::INET', 'Mocking console_open');
$retval = $master->console_close();
is($retval, "mocked console_close", 'Mocking console_close');


$retval = $master->set_interrupt_handlers();
is($retval, 0, 'Set interrupt handlers');

$retval = $master->prepare_server();
is($retval, 0, 'Setting object attributes');
isa_ok($master->{readset}, 'IO::Select', 'Readset attribute');


$retval = $master->runloop(time());

my $job = model('TestrunDB')->resultset('TestrunScheduling')->find(101);
$job->status('schedule');
$job->testrun->rerun_on_error(2);
my @old_test_ids = map{$_->id} model('TestrunDB')->resultset('Testrun')->all;
$master->run_due_tests($job);
wait();
my @new_test_ids = map{$_->id} model('TestrunDB')->resultset('Testrun')->all;
cmp_bag([@old_test_ids, 3004], [@new_test_ids], 'New test because of rerun_on_error, no old test deleted');

$mockmaster->unmock('console_open');
my $mocknet = Test::MockModule->new('Tapper::MCP::Net');

my $outdir = File::Temp::tempdir(CLEANUP => 1);
$master->cfg->{paths}{output_dir} = $outdir;
$mocknet->mock('conserver_connect', sub {sleep 10;});
$retval = $master->console_open('bascha', 1234);
is($retval, 'Unable to open console for bascha after 5 seconds', 'Timeout for console_open');
ok(-d "$outdir/1234", 'Output dir created');
done_testing();
