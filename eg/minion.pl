#!/opt/perl

use Mojolicious::Lite;

app->log->level("debug");

plugin Minion => { SQLite => 'sqlite:test.db' };
plugin ForkAndGo => "minion";

app->minion->add_task(joy => sub {
    my ($job, @args) = @_;

    $job->app->log->info("Weeee");

    $job->finish;
});

get '/' => sub {
    my $c = shift;

    # Have fun later
    my $job_id = $c->minion->enqueue("joy");

    $c->render(text => "Hello:" . $job_id);
};

app->start;
