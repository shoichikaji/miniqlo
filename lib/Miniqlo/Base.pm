package Miniqlo::Base;
use 5.22.0;
use warnings;
use utf8;
use feature ();
use experimental ();

sub import {
    $_->import for qw(strict warnings utf8);
    feature->import(":5.22");
    experimental->import(qw(postderef signatures));
}

1;
