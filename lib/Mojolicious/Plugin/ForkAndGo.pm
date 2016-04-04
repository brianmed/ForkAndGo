package Mojolicious::Plugin::ForkAndGo;
use Mojo::Base 'Mojolicious::Plugin';

use Mojo::IOLoop;
use IO::Pipely 'pipely';
use POSIX qw(setsid);
use Scalar::Util qw(openhandle looks_like_number weaken);
use Devel::Refcount qw(refcount);
use File::Spec::Functions qw(catfile tmpdir);
use File::Basename 'dirname';
 
our $VERSION = '0.01';
our $app;
our $state = {};

use constant DEBUG => $ENV{MOJOLICIOUS_PLUGIN_FORKANDGO_DEBUG} || 0;

sub register {
  my ($self, $app) = @_;

  $Mojolicious::Plugin::ForkAndGo::app = $app;

  $app->helper(forked => sub {
    my $code = pop;

    return unless __PACKAGE__->in_server;

    my $code_key = "$code";
    my $toady_current_pid = __PACKAGE__->hypnotoad_pid;

    my ($r, $w) = pipely;

    # TODO: Somehow clean leak this up
    my $state = $Mojolicious::Plugin::ForkAndGo::state;
    $state->{code}{$code_key}{r} = $r;
    $state->{code}{$code_key}{w} = $w;

    $state->{callback}{$code_key} = $code;
    $state->{toady_current_pid}{$code_key} = $toady_current_pid;

    __PACKAGE__->fork($code_key);
  });
}

sub callback {
  my $code_key = pop;

  my $state = $Mojolicious::Plugin::ForkAndGo::state;
  my $code = $state->{callback}{$code_key};

  my $hypnotoad_state = __PACKAGE__->hypnotoad_state($code_key);

  if ("empty_unknown" eq $hypnotoad_state) {
    Mojo::IOLoop->timer(0.1 => $code);
  }
  elsif ("running" eq $hypnotoad_state) {
    Mojo::IOLoop->timer(0.1 => $code);
  }
  elsif ("restarting" eq $hypnotoad_state) {
    Mojo::IOLoop->timer(0.1 => $code);
  }
  elsif ("startup" eq $hypnotoad_state) {
    $code->($app);
  }
  elsif ("not_hypnotoad" eq $hypnotoad_state) {
    $code->($app);
  }
}

sub in_server {
  my $ret = 0;

  my $state = $Mojolicious::Plugin::ForkAndGo::state;

  # Only if started as a server
  my $hypnotoad = $ENV{HYPNOTOAD_REV} && 2 <= $ENV{HYPNOTOAD_REV} ? 1 : 0;
  $ret = 1 if ($ARGV[0] && $ARGV[0] =~ m/^(daemon|prefork)$/) || $hypnotoad;

  $app->log->info(sprintf("$$: in_server: %s - %s - $ARGV[0]: $ret", ($ENV{HYPNOTOAD_REV} // ""), ($ENV{HYPNOTOAD_STOP} // "")));

  return $ret;
}

sub hypnotoad_state {
  my $code_key = pop;

  my $state = $Mojolicious::Plugin::ForkAndGo::state;

  my $toady_current_pid = $state->{toady_current_pid}{$code_key};
  my $toady_starting_pid = __PACKAGE__->hypnotoad_pid;

  my $toady_current_alive = $toady_current_pid ? kill("SIGZERO", $toady_current_pid) : 0;
  my $toady_starting_alive = $toady_starting_pid ? kill("SIGZERO", $toady_starting_pid) : 0;

  $app->log->info(
      "$$: ForkAndGo hypnotoad_state: %s: %s: %s: %s",
      ($toady_starting_pid // ""),
      ($toady_current_pid // ""),
      ($toady_current_alive // ""),
      ($toady_starting_alive // ""),
  ) if DEBUG;

  my $ret = "";

  if (defined $toady_starting_pid) {

      if ("" eq $toady_starting_pid) {
        $ret = "empty_unknown";
      }
      elsif ($toady_current_pid == $toady_starting_pid) {
        $ret = "running";
      }
      elsif (
          $toady_current_pid && $toady_starting_pid &&
          $toady_current_pid != $toady_starting_pid && 
          $toady_current_alive &&
          $toady_starting_alive
      ) {
        $ret = "restarting";
      }
      else {
        $ret = "startup";
      }
  }
  else {
      $ret = "not_hypnotoad";
  }

  $app->log->info("$$: ForkAndGo hypnotoad_state: $ret") if DEBUG;

  return $ret;
}

sub fork {
  my $code_key = pop;

  my $state = $Mojolicious::Plugin::ForkAndGo::state;

  my $r = $state->{code}{$code_key}{r};
  my $w = $state->{code}{$code_key}{w};

  die "Can't fork: $!" unless defined(my $pid = fork);
  if ($pid) { # Parent
    close($r);

    $app->log->info("$$: Parent return: $$: $pid") if DEBUG;

    return $pid;
  }
  close($w);
  POSIX::setsid or die "Can't start a new session: $!";

  # Child
  Mojo::IOLoop->reset;

  my $stream = Mojo::IOLoop::Stream->new($r)->timeout(0);
  Mojo::IOLoop->stream($stream);

  $stream->on(error => sub { 
    $app->log->info("$$: Child exiting: error: $$: $_[0]: $_[1]: $_[2]") if DEBUG;

    __PACKAGE__->_cleanup;

    exit;
  });
  $stream->on(close => sub { 
    $app->log->info("$$: Child exiting: close: $$: $_[0]") if DEBUG;

    __PACKAGE__->_cleanup;

    exit;
  });

  Mojo::IOLoop->recurring(1 => sub {
    my $loop = shift;

    my $str = sprintf("$$: %s: %s: $r", refcount($r), openhandle($r) // "CLOSED");
    $app->log->info("$$: Child recurring: $str") if DEBUG;
  });

  __PACKAGE__->callback($code_key);

  return $pid;
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
    my $app = $Mojolicious::Plugin::ForkAndGo::app;

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
