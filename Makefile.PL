#!/usr/bin/perl

use ExtUtils::MakeMaker;

sub MY::postamble {
   package MY;
   "\npredist: all\n" .
#   "\tcvs2cl\n" .
   "\t\$(MAKE) manifest\n" .
   "\t\$(MAKE) tardist\n"
}

WriteMakefile(
   MAKEFILE => 'Makefile',
   VERSION_FROM => 'lib/POE/Component/Client/Dashboard.pm',
   NAME => 'POE::Component::Client::Dashboard',
   PREREQ_PM => {
      'POE' => '0.25',
      'POE::Component::Client::DNS' => 0,
   },
   dist => {
      COMPRESS     =>'gzip',
      SUFFIX       =>'gz',
      DIST_DEFAULT => 'predist',
   },
);
