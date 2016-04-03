package Mojolicious::Plugin::ForkAndGo;
use Mojo::Base 'Mojolicious::Plugin';

use Mojo::IOLoop;
use IO::Pipely 'pipely';
use POSIX qw(setsid);
use Scalar::Util qw(openhandle);
use Devel::Refcount qw(refcount);
 
our $VERSION = '0.01';

has 'ioloop' => sub { Mojo::IOLoop->singleton };

sub register {
  my ($self, $app, $ops) = @_;

  $app->log->debug(sprintf("Parent: %s: %s: %s: %s: %s", 
      ($ENV{FORKANDGO_PLUGIN_REV} // ""),
      ($ENV{HYPNOTOAD_REV} // ""),
      ($ENV{HYPNOTOAD_PID} // ""),
      ($ENV{HYPNOTOAD_STOP} // ""),
      join(", ", @ARGV)
  ));

  # hack to run once and only at server startup
  ++$ENV{FORKANDGO_PLUGIN_REV};
  return if $ENV{FORKANDGO_PLUGIN_REV} > 1;

  return if $ENV{HYPNOTOAD_STOP};
  return if $ENV{HYPNOTOAD_PID};
  my $hypnotoad = 1 if $ENV{HYPNOTOAD_REV} && 2 == $ENV{HYPNOTOAD_REV};

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

        $app->log->info("Parent return: $$: $pid");

        next;
      }
      close($w);
      POSIX::setsid or die "Can't start a new session: $!";

      Mojo::IOLoop->reset;

      my $stream = Mojo::IOLoop::Stream->new($r)->timeout(0);
      $self->ioloop->stream($stream);

      $stream->on(error => sub { 
        $app->log->info("Child exiting: error: $$: $_[0]: $_[1]: $_[2]");

        $self->_cleanup($app);

        exit;
      });
      $stream->on(close => sub { 
        $app->log->info("Child exiting: close: $$: $_[0]");

        $self->_cleanup($app);

        exit;
      });

      Mojo::IOLoop->recurring(1 => sub {
        my $loop = shift;

        my $str = sprintf("$$: %s: %s: $r", refcount($r), openhandle($r) // "CLOSED");
        $app->log->info("Child recurring: $str");
      });

      $code->($app);

      Mojo::IOLoop->start;
  }
}

sub _cleanup {
    my $self = shift;
    my $app = shift;

    $app->log->info("Child KILL: $$");

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
