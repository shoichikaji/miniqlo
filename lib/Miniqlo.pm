package Miniqlo;
use Miniqlo::Base;
use Miniqlo::DB;
use Miniqlo::Cron;
use Path::Tiny ();

use parent 'Amon2';
__PACKAGE__->make_local_context;

sub db ($self) {
    $self->{db} ||= do {
        my $dbname = $self->base_dir . "/var/history.sqlite";
        Miniqlo::DB->new(connect_info => ["dbi:SQLite:dbname=$dbname", "", ""]);
    };
}
sub log_dir ($self)     { $self->base_dir . "/var/log" }
sub running_dir ($self) { $self->base_dir . "/var/running" }
sub load_cron ($self) {
    my @file = Path::Tiny->new($self->base_dir, "job")->children(qr/\.(yaml|yml|json)$/n);
    map { Miniqlo::Cron->new($self, $_) } @file;
}

1;
