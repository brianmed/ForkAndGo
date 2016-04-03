package Mojolicious::Plugin::ForkAndGo;
use Mojo::Base 'Mojolicious::Plugin';

use Mojo::IOLoop;
use IO::Pipely 'pipely';
use POSIX qw(setsid);
use Scalar::Util qw(openhandle looks_like_number);
use Devel::Refcount qw(refcount);
use File::Spec::Functions qw(catfile tmpdir);
use File::Basename 'dirname';
 
our $VERSION = '0.01';

use constant DEBUG => $ENV{MOJOLICIOUS_PLUGIN_FORKANDGO_DEBUG} || 0;

sub register {
  my ($self, $app, $ops) = @_;

  my $toady_current_pid = $self->hypnotoad_pid;

  $app->log->debug(sprintf("$$: Parent: %s: %s: %s: %s: %s: %s", 
      ($ENV{FORKANDGO_PLUGIN_REV} // ""),
      ($ENV{HYPNOTOAD_REV} // ""),
      ($ENV{HYPNOTOAD_PID} // ""),
      ($ENV{HYPNOTOAD_STOP} // ""),
      $toady_current_pid // "undef",
      join(", ", @ARGV)
  )) if DEBUG;

  # hack to run once and only at server startup/restart
  ++$ENV{FORKANDGO_PLUGIN_REV};
  return if $ENV{FORKANDGO_PLUGIN_REV} > 1 && !($ENV{HYPNOTOAD_REV} && 3 <= $ENV{HYPNOTOAD_REV});

  return if $ENV{HYPNOTOAD_STOP};
  my $hypnotoad = $ENV{HYPNOTOAD_REV} && 2 <= $ENV{HYPNOTOAD_REV} ? 1 : 0;

  return unless ($ARGV[0] && $ARGV[0] =~ m/^(daemon|prefork)$/) || $hypnotoad;

  foreach my $code (@{ $ops->{code} }) {
      my ($r, $w) = pipely;

      $app->helper("_pipes_hack" . "$code" => sub { ## Hack
        my $ha = $r;
        my $ck = $w;
      });

      die "Can't fork: $!" unless defined(my $pid = fork);
      if ($pid) {
        close($r);

        $app->log->info("$$: Parent return: $$: $pid") if DEBUG;

        next;
      }
      close($w);
      POSIX::setsid or die "Can't start a new session: $!";

      Mojo::IOLoop->reset;

      my $stream = Mojo::IOLoop::Stream->new($r)->timeout(0);
      Mojo::IOLoop->stream($stream);

      $stream->on(error => sub { 
        $app->log->info("$$: Child exiting: error: $$: $_[0]: $_[1]: $_[2]") if DEBUG;

        $self->_cleanup($app);

        exit;
      });
      $stream->on(close => sub { 
        $app->log->info("$$: Child exiting: close: $$: $_[0]") if DEBUG;

        $self->_cleanup($app);

        exit;
      });

      Mojo::IOLoop->recurring(1 => sub {
        my $loop = shift;

        my $str = sprintf("$$: %s: %s: $r", refcount($r), openhandle($r) // "CLOSED");
        $app->log->info("$$: Child recurring: $str") if DEBUG;
      });

      my $callback; $callback = sub {
        my $toady_starting_pid = $self->hypnotoad_pid;

        if (defined $toady_starting_pid) {
            if ("" eq $self->hypnotoad_pid) {
              $app->log->info("$$: Deferring ForkAndGo callback: empty") if DEBUG;
              Mojo::IOLoop->timer(0.1 => $callback);
            }
            elsif ($toady_current_pid == $toady_starting_pid) {
              $app->log->info("$$: Deferring ForkAndGo callback: alive $toady_current_pid == alive $toady_starting_pid") if DEBUG;
              Mojo::IOLoop->timer(0.1 => $callback);
            }
            elsif (
                $toady_current_pid && $toady_starting_pid &&
                $toady_current_pid != $toady_starting_pid && 
                kill("SIGZERO", $toady_current_pid) &&
                kill("SIGZERO", $toady_starting_pid)
            ) {
              $app->log->info("$$: Deferring ForkAndGo callback: alive $toady_current_pid != alive $toady_starting_pid") if DEBUG;
              Mojo::IOLoop->timer(0.1 => $callback);
            }
            else {
              $app->log->info("$$: Running ForkAndGo callback: " . $self->hypnotoad_pid) if DEBUG;
              $code->($app);
            }
        }
        else {
            $app->log->info("$$: Running ForkAndGo callback") if DEBUG;
            $code->($app);
        }
      };

      Mojo::IOLoop->next_tick(sub { # Let the server initialize
        $app->log->info("$$: Setting next_tick: $$: $code: " . ($toady_current_pid // "undef")) if DEBUG;

        Mojo::IOLoop->next_tick(sub { # Let the server restart, if needed
            $callback->();
        });
      });

      Mojo::IOLoop->start;
  }
}

sub hypnotoad_pid {
  return undef unless $ENV{HYPNOTOAD_APP};

  my $file = catfile(dirname($ENV{HYPNOTOAD_APP}), 'hypnotoad.pid');

  return 0 unless open my $handle, '<', $file;
  my $pid = <$handle> // "";
  chomp $pid;

  # Inditermiante?
  return "" if !looks_like_number($pid);

  # Running
  return $pid if $pid && kill 0, $pid;

  # Not running
  return 0;
}

sub _cleanup {
    my $self = shift;
    my $app = shift;

    $app->log->info("$$: Child KILL: $$") if DEBUG;

    kill('-KILL', $$);
}

1;
__END__

=encoding utf8

=head1 NAME

Mojolicious::Plugin::ForkAndGo - Mojolicious Plugin

=head1 SYNOPSIS

  # Mojolicious
  $self->plugin('ForkAndGo');

  # Mojolicious::Lite
  plugin 'ForkAndGo';

=head1 DESCRIPTION

L<Mojolicious::Plugin::ForkAndGo> is a L<Mojolicious> plugin.

=head1 METHODS

L<Mojolicious::Plugin::ForkAndGo> inherits all methods from
L<Mojolicious::Plugin> and implements the following new ones.

=head2 register

  $plugin->register(Mojolicious->new);

Register plugin in L<Mojolicious> application.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicious.org>.

=cut
