package Miniqlo::RunningFile;
use Miniqlo::Base;
use Miniqlo::Util 'with_timeout';
use Fcntl ();

sub new ($class, $path) {
    bless { path => $path, fh => undef }, $class;
}

sub path ($self) { $self->{path} }
sub fh ($self) {
    $self->{fh} ||= do {
        open my $fh, "+>>", $self->path or die "Cannot open @{[$self->path]}: $!";
        $fh;
    };
}

sub is_running ($self) {
    return 0 unless -f $self->path;
    if ($self->lock) {
        $self->unlock;
        0;
    } else {
        1;
    }
}

sub lock ($self, $timeout = 0) :method {
    my $fh = $self->fh;
    if ($timeout) {
        my $ok = with_timeout $timeout, sub {
            flock $fh, Fcntl::LOCK_SH;
        };
        return $ok;
    } else {
        return flock $fh, Fcntl::LOCK_SH | Fcntl::LOCK_NB;
    }
}

sub unlock ($self) {
    flock $self->fh, Fcntl::LOCK_UN;
}

sub unlink ($self) :method {
    close $self->fh if $self->fh;
    unlink $self->path;
}

1;
