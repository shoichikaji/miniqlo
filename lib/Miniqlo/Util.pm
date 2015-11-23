package Miniqlo::Util;
use Miniqlo::Base;

use Exporter 'import';
our @EXPORT_OK = qw(with_timeout);

sub with_timeout ($sec, $code) {
    my $wantarray = wantarray;
    my @out;
    eval {
        local $SIG{__DIE__} = 'DEFAULT';
        local $SIG{ALRM} = sub { die "alarm\n" };
        alarm $sec;
        if ($wantarray) {
            @out = $code->();
        } else {
            $out[0] = $code->();
        }
        alarm 0;
    };
    alarm 0;
    if ($@ && $@ ne "alarm\n") {
        die $@;
    } else {
        $wantarray ? @out : $out[0];
    }
}

1;
