#!/opt/perl

use Mojolicious::Lite;

app->log->level("debug");

plugin Minion => { SQLite => 'sqlite:test.db' };
plugin qw(Mojolicious::Plugin::ForkCall);
plugin ForkAndGo => { code => [
    sub {
      my $app = shift;
      
      $app->fork_call(
        sub {
          system($^X, $0, "minion", "worker");
        },
        sub {
          exit;
        }
      );
  }, sub {
      my $app = shift;
      
      Mojo::IOLoop->server({port => 4000} => sub {
        my ($loop, $stream, $id) = @_;
      
        $stream->on(read => sub {
          my ($stream, $bytes) = @_;
      
          $app->log->debug("$$: read: $bytes");
        });
      });
  }]
};

app->minion->add_task(echo => sub {
    my ($job, @args) = @_;

    my $id; $id = Mojo::IOLoop->client({port => 4000} => sub {
      my ($loop, $err, $stream) = @_;

      $stream->on(drain => sub {
        $job->finish;

        Mojo::IOLoop->remove($id);
        Mojo::IOLoop->stop;
      });

      $stream->write($args[0]);
    });

    Mojo::IOLoop->start;
});

get '/' => sub {
    my $c = shift;

    my $job_id = $c->minion->enqueue("echo", ["Joy: $$"]);

    $c->render(text => "Hello:" . $job_id);
};

app->start;
