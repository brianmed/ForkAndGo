package Mojolicious::Plugin::ForkAndGo;
use Mojo::Base 'Mojolicious::Plugin';

use Mojo::IOLoop;
use IO::Pipely 'pipely';
use POSIX qw(setsid);
use Scalar::Util qw(openhandle looks_like_number weaken);
use Devel::Refcount qw(refcount);
use File::Spec::Functions qw(catfile tmpdir);
use IO::Handle;
use Fcntl;
use Mojo::Util qw(slurp spurt);
 
our $VERSION = '0.01';
our $app;
our $state = {};
our $pkg = __PACKAGE__;

use constant DEBUG => $ENV{MOJOLICIOUS_PLUGIN_FORKANDGO_DEBUG} || 0;

sub register {
  my ($self, $app) = @_;

  $Mojolicious::Plugin::ForkAndGo::app = $app;

  my $forked = catfile(tmpdir, 'forkngo.state');

  if ($ENV{HYPNOTOAD_EXE} && ($ENV{HYPNOTOAD_REV} && 2 == $ENV{HYPNOTOAD_REV})) {
    unlink($forked);
  }
  elsif (!$ENV{MOJO_REUSE} && !$ENV{MOJOLICIOUS_PLUGIN_FORKANDGO_REV}) {
    unlink($forked);
  }

  ++$ENV{MOJOLICIOUS_PLUGIN_FORKANDGO_REV};

  $app->helper(forked => sub {
    my $code = pop;

    Mojo::IOLoop->next_tick(sub {
      # TODO: Somehow clean leak this up
      my $code_key = "$code";

      # Create forks on same worker
      eval {
          sysopen(my $fh, $forked, O_RDWR|O_CREAT|O_EXCL) or die;
          spurt($$, $forked);
      };
      if ($@) {
          my $do_over = slurp($forked);
          return unless $do_over == $$;

          $app->log->info("$$: created[1] next_tick: $forked") if DEBUG;
      }
      else {
          $app->log->info("$$: created[0] next_tick: $forked") if DEBUG;
      }

      my ($r, $w) = pipely;
      
      $state->{code}{$code_key}{r} = $r;
      $state->{code}{$code_key}{w} = $w;

      $state->{callback}{$code_key} = $code;

      $pkg->fork($code_key);
    });
  });
}

sub fork {
  my $code_key = pop;

  my $r = $state->{code}{$code_key}{r};
  my $w = $state->{code}{$code_key}{w};

  die "Can't fork: $!" unless defined(my $pid = fork);
  if ($pid) { # Parent
    close($r);

    return $pid;
  }
  close($w);
  POSIX::setsid or die "Can't start a new session: $!";

  $app->log->info("$$: Child running: $$: " . getppid);

  # Child
  Mojo::IOLoop->reset;

  my $stream = Mojo::IOLoop::Stream->new($r)->timeout(0);
  Mojo::IOLoop->stream($stream);

  $stream->on(error => sub { 
    $app->log->info("$$: Child exiting: error: $$: $_[1]");

    $pkg->_cleanup;

    exit;
  });
  $stream->on(close => sub { 
    $app->log->info("$$: Child exiting: close: $$");

    $pkg->_cleanup;

    exit;
  });

  Mojo::IOLoop->recurring(1 => sub {
    my $loop = shift;

    my $str = sprintf("%s: %s: %s: $r", getppid, refcount($r), openhandle($r) // "CLOSED");
    $app->log->info("$$: Child recurring: $str");
  }) if DEBUG;

  my $code = $state->{callback}{$code_key};
  $code->($app);

  return $pid;
}

sub _cleanup {
    $app->log->info("$$: Child -KILL: $$") if DEBUG;

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
