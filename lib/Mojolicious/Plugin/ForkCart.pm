package Mojolicious::Plugin::ForkCart;
use Mojo::Base 'Mojolicious::Plugin';

use Time::HiRes qw(usleep);

our $VERSION = '0.02';
our $pkg = __PACKAGE__;

our $caddy_pkg = "${pkg}::Caddy";
our $plugin_pkg = "${pkg}::Plugin";
our $count = 0;

use constant DEBUG => $ENV{MOJOLICIOUS_PLUGIN_FORKCART_DEBUG} || 0;

sub register {
  my ($cart, $app, $ops) = @_;

  my $caddy = $caddy_pkg->new(app => $app);

  if ($caddy->is_alive && $ENV{HYPNOTOAD_STOP}) {
    my $state = $caddy->state;
    $state->{shutdown} = 1;
    $caddy->state($state);

    return;
  }

  if ($caddy->is_alive && !$ENV{MOJOLICIOUS_PLUGIN_FORKCART_ADD}) {
    $app->log->info("$$: " . ($caddy->state->{caddy_pid} // "") . " is alive: shutdown");

    my $state = $caddy->state;
    $state->{shutdown} = 1;
    $caddy->state($state);

    while ($caddy->is_alive) {
      $app->log->info("$$: " . ($caddy->state->{caddy_pid} // "") . " is alive: waiting");

      usleep(50000);
    }

    unlink($caddy->state_file);
  } elsif ($caddy->is_alive) {
    $app->log->info("$$: " . ($caddy->state->{caddy_pid} // "") . " is alive: $ENV{MOJOLICIOUS_PLUGIN_FORKCART_ADD}");

  } elsif ($ARGV[0] && $ARGV[0] =~ m/^(daemon|prefork)$/) {
    my $state_file = $caddy->state_file;

    $app->log->info("$$: $ARGV[0]: unlink($state_file)");

    unlink($state_file);
  } elsif ($ENV{HYPNOTOAD_REV} && 2 <= $ENV{HYPNOTOAD_REV}) {
    my $state_file = $caddy->state_file;

    $app->log->info("$$: hypnotoad: unlink($state_file)");

    unlink($state_file);
  }

  $app->helper(forked => sub {
    ++$count;

    Mojo::IOLoop->next_tick($caddy->add(pop));
  });

  if ($ops->{process}) {
    $plugin_pkg->$_($caddy) for @{ $ops->{process} };
  }
}

package Mojolicious::Plugin::ForkCart::Plugin;
use Mojo::Base -base;

use constant DEBUG => Mojolicious::Plugin::ForkCart::DEBUG;

sub minion {
  my $caddy = pop;

  my $app = $caddy->app;

  $app->plugin(qw(Mojolicious::Plugin::ForkCall)) 
    unless $app->can("fork_call");

  $app->forked(sub {
    my $app = shift;

    $app->log->info("$$: Child forked: " . getppid);

    $app->fork_call(
      sub {
        $app->log->info("$$: Child fork_call: " . getppid);

        # I dunno why I have (or if I have) to do this for hypnotoad
        delete($ENV{HYPNOTOAD_APP});
        delete($ENV{HYPNOTOAD_EXE});
        delete($ENV{HYPNOTOAD_FOREGROUND});
        delete($ENV{HYPNOTOAD_REV});
        delete($ENV{HYPNOTOAD_STOP});
        delete($ENV{HYPNOTOAD_TEST});
        delete($ENV{MOJO_APP_LOADER});
        
        my @cmd = (
            $^X,
            $0,
            "minion",
            "worker"
        );
        $0 = join(" ", @cmd);

        $app->log->debug("$$: ForkCart minion worker") if DEBUG;
        system(@cmd) == 0 
            or die("0: $?");

        return 1;
      },
      sub {
        exit;
      }
    );
  });
}

package Mojolicious::Plugin::ForkCart::Caddy;
use Mojo::Base -base;

use Mojo::IOLoop;
use Devel::Refcount qw(refcount);
use File::Spec::Functions qw(catfile tmpdir);
use IO::Handle;
use Fcntl qw(O_RDWR O_CREAT O_EXCL LOCK_EX SEEK_SET LOCK_UN :flock);
use Mojo::Util qw(slurp spurt steady_time);
use Mojo::JSON qw(encode_json decode_json);
use POSIX qw(:sys_wait_h);
use Time::HiRes qw(usleep);

our %code = ();
our $created = 0;

has qw(app);
has state_file => sub { catfile tmpdir, 'forkngo.state_file' };

use constant DEBUG => Mojolicious::Plugin::ForkCart::DEBUG;

sub watchdog {
  my $caddy = shift;

  return sub {
    my $state = $caddy->state;

    # exit unless kill("SIGZERO", $caddy->state->{caddy_manager}) || $caddy->state->{shutdown};
    kill("-KILL", getpgrp) if $caddy->state->{shutdown};

    $caddy->app->log->info("$$: Caddy recurring: " . scalar(keys %{$state->{slots}}));
  };
};

sub is_alive {
  my $caddy = shift;

  return $caddy->state->{caddy_pid} ? kill("SIGZERO", $caddy->state->{caddy_pid}) : 0;
}

sub lock {
    my $fh = pop;
    flock($fh, LOCK_EX) or die "Cannot lock ? - $!\n";

    # and, in case someone appended while we were waiting...
    seek($fh, 0, SEEK_SET) or die "Cannot seek - $!\n";
}

sub unlock {
    my $fh = pop;
    flock($fh, LOCK_UN) or die "Cannot unlock ? - $!\n";
}

sub state {
  my $caddy = shift;
  my $new_state = shift;

  # Should be created by sysopen
  my $fh;
  if (-f $caddy->state_file && -s $caddy->state_file) {
    open($fh, ">>", $caddy->state_file)
      or die(sprintf("Can't open %s", $caddy->state_file));

    $caddy->lock($fh);
  }
  elsif (!$new_state) {
    return {};
  }

  if ($new_state) {
    spurt(encode_json($new_state), $caddy->state_file);

    $caddy->unlock($fh);

    return $new_state;
  }
  elsif (-f $caddy->state_file) {
    my $ret = decode_json(slurp($caddy->state_file));

    $caddy->unlock($fh);

    return $ret;
  }
  else {
    $caddy->unlock($fh);

    return {};
  }
}

sub is_me {
    my $state = shift->state;
    return 0 if !defined $state->{caddy_pid};
    return $state->{caddy_pid} == $$;
}

sub add {
  my $caddy = shift;

  my $code_key = steady_time;
  $code{$code_key} = shift;

  return sub {
    my $state_file = $caddy->state_file;
    
    my $app = $caddy->app;
    
    eval {
      $app->log->info("$$: Worker next_tick");
    
      sysopen(my $fh, $state_file, O_RDWR|O_CREAT|O_EXCL) or die("$state_file: $$: $!\n");
      spurt(encode_json({ shutdown => 0, caddy_pid => $$, caddy_manager => $ARGV[0] && $ARGV[0] =~ m/daemon/ ? $$ : getppid }), $state_file);
      close($fh);
    };
    
    # Outside the caddy
    if ($@ && !$caddy->is_me) {
      chomp(my $err = $@);
    
      $app->log->info("$$: sysopen($state_file): $err");
    
      return sub { };
    }
    
    return if !$caddy->is_me;
    
    # Inside the caddy
    $app->log->info("$state_file: sysopen($$) <-- caddy: " . ($ENV{MOJOLICIOUS_PLUGIN_FORKCART_ADD} // 'undef'));
    
    my $state = $caddy->state;
    my $slots = $state->{slots} //= {};
    
    $slots->{$code_key} = {};
    $slots->{$code_key}{created} = $created;
    
    ++$ENV{MOJOLICIOUS_PLUGIN_FORKCART_ADD};
    spurt(encode_json($state), $state_file);
    
    $app->log->info("$$-->: $created: $Mojolicious::Plugin::ForkCart::count") if DEBUG;
    
    # Create the slots in the caddy
    Mojo::IOLoop->next_tick($caddy->create) if ++$created == $Mojolicious::Plugin::ForkCart::count;
  };
}

sub create {
  my $caddy = shift;

  $caddy->app->log->info("$$: Caddy create");

  return(sub {
    my $state = $caddy->state;
    my $app = $caddy->app;

    # Belt and suspenders error checking, shouldn't be reached (I think)
    if ($state->{caddy} && $$ != $state->{caddy}) {
        my $msg = "We are not the caddy";

        $app->log->error($msg);

        die($msg);
    }

    $app->log->info("$$: caddy->state->{caddy_manager}: " . $caddy->state->{caddy_manager});

    # Watchdog
    Mojo::IOLoop->recurring(1 => $caddy->watchdog);

    foreach my $code_key (keys %{ $state->{slots} }) {
        $app->log->info("$$: $code_key: $code{$code_key}");

        my $pid = $caddy->fork($code{$code_key});

        $state->{slots}{$code_key}{pid} = $pid if $$ != $pid;
        $caddy->state($state) if $$ != $pid;
    }
  });
}

sub fork {
  my $caddy = shift;
  my $code = shift;
  
  my $app = $caddy->app;

  my $pgroup = getpgrp;

  die "Can't fork: $!" unless defined(my $pid = fork);
  if ($pid) { # Parent

    $app->log->info("$$: Parent return");

    $SIG{CHLD} = sub {
      while ((my $child = waitpid(-1, WNOHANG)) > 0) {
        $app->log->info("$$: Parent waiting: $child");
      }
    };

    return $pid;
  }

  $app->log->info("$$: Slot running: $$: " . getppid);

  setpgrp($pid, $pgroup);

  # Caddy's Child
  Mojo::IOLoop->reset;

  Mojo::IOLoop->recurring(1 => sub {
    my $loop = shift;

    my $str = sprintf("%s", join(", ", @{ $caddy->state }{'caddy_manager', 'shutdown'}));
    $app->log->info("$$: Caddy slot monitor: $str");

    # TODO: Do a graceful stop
    kill("-KILL", $pgroup) if $caddy->state->{shutdown} || !$caddy->is_alive;
  });

  $code->($app);

  Mojo::IOLoop->start;

  return $$;
}

sub pid_wait {
  my ($pid, $timeout) = @_;

  my $ret;

  my $done = steady_time + $timeout;
  do {
    $ret = kill("SIGZERO", $pid);

    usleep 50000 if $ret;

  } until(!$ret || $done < steady_time);

  return !$ret;
}

1;

__END__

=encoding utf8

=head1 NAME

Mojolicious::Plugin::ForkCart - Mojolicious Plugin

=head1 SYNOPSIS

  # Mojolicious
  $cart->plugin('ForkCart');

  # Mojolicious::Lite
  plugin 'ForkCart';

=head1 DESCRIPTION

L<Mojolicious::Plugin::ForkCart> is a L<Mojolicious> plugin.

=head1 METHODS

L<Mojolicious::Plugin::ForkCart> inherits all methods from
L<Mojolicious::Plugin> and implements the following new ones.

=head2 register

  $plugin->register(Mojolicious->new);

Register plugin in L<Mojolicious> application.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicious.org>.

=cut
