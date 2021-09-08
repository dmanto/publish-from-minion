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

  # $c->minion->perform_jobs_in_foreground;   # this works
  $c->minion->perform_jobs;    # this doesn't
      # also, if you comment out both lines above, and run the minion worker
      # from another terminal, like this:
      # $> perl pub_from_minion.t minion worker
      # then everything works fine.

  # will check for finished minion, just using a small interval
  $c->minion->result_p($job_id, {interval => .1})->then(sub ($info) {
    $c->pg->pubsub->unlisten(channel => $cb);
    $c->render(text => $received);
  })->catch(sub ($info) {
    $c->render(text => "Error: $info");
  });
};

app->start;    # this is needed for the minion worker when called standalone

my $t = Test::Mojo->new;
$t->get_ok('/')->content_is('Hello from minion job');

done_testing;
