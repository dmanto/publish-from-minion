use Mojo::Base -strict;

BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use Test::Mojo;
use Test::More;

use Mojolicious::Lite -signatures;
use Mojo::Pg;

my $dbstring = 'postgresql:///test';    # or whatever

helper pg     => sub { state $pg = Mojo::Pg->new($dbstring) };
plugin Minion => {Pg => $dbstring};

my $minion = app->minion;

$minion->add_task(
  send_back => sub ($job) {

    # send back a message using app's pg helper, then just finish
    $job->app->pg->pubsub->reset if $job->app->mode ne 'production';
    $job->app->pg->pubsub->notify(channel => "Hello from minion job");
    $job->finish;
  }
);

get '/' => sub ($c) {
  $c->render_later;
  my $received;
  my $cb = $c->pg->pubsub->listen(
    channel => sub ($pubsub, $message) {
      $received = $message;
      $c->log->debug("Message $message arrived");
    }
  );
  my $job_id = $c->minion->enqueue('send_back');

  # will check for finished minion, just using a small interval
  $c->minion->result_p($job_id, {interval => .1})->then(sub ($info) {
    $c->pg->pubsub->unlisten(channel => $cb);
    $c->render(text => $received);
  })->catch(sub ($info) {
    $c->render(text => "Error: $info");
  });
};
Mojo::IOLoop->recurring(
  1 => sub {
    $minion->perform_jobs;
  }
) if app->mode ne 'production';
app->start;    # this is needed for the minion worker when called standalone

my $t = Test::Mojo->new;
$t->get_ok('/')->content_is('Hello from minion job');

done_testing;
