use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
  NAME         => 'Mojolicious::Plugin::ForkAndGo',
  VERSION_FROM => 'lib/Mojolicious/Plugin/ForkAndGo.pm',
  AUTHOR       => 'A Good Programmer <nospam@cpan.org>',
  PREREQ_PM    => {'Mojolicious' => '6.57'},
  test         => {TESTS => 't/*.t'}
);
