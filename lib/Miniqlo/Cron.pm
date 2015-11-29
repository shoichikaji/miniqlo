package Miniqlo::Cron;
use Miniqlo::Base;
use Miniqlo::RunningFile;
use YAML::Loader;
use JSON::PP ();
use Path::Tiny ();
use Process::Status;
use Scalar::Util ();

my $YAML = YAML::Loader->new;
my $JSON = JSON::PP->new->utf8(0);

sub new ($class, $c, $file) {
    my $path = ref $file ? $file : Path::Tiny->new($file);
    my $hash;
    if ($file =~ /\.(yaml|yml)$/n) {
        $hash = $YAML->load($path->slurp_utf8);
    } elsif ($file =~ /\.json$/) {
        $hash = $JSON->decode($path->slurp_utf8);
    } else {
        die "Unknown file format $file";
    }
    ($hash->{name}) = $path->basename =~ /(.+)\.(?:yaml|yml|json)$/;
    if ($hash->{name} =~ /^_/) {
        die "Cron name cannot be started with '_' ($file)\n";
    }
    $hash->{c} = $c;
    Scalar::Util::weaken($hash->{c});
    bless $hash, $class;
}

sub script ($self) { $self->{script} }
sub name   ($self) { $self->{name}   }
sub every  ($self) { $self->{every}  }

sub c ($self) { $self->{c} }
sub db ($self) { $self->c->db }

sub log_file ($self, $time) {
    my $file = sprintf "%s/%s", $self->name, $time->strftime("%Y-%m-%d/%H-%M-%S.txt");
    Path::Tiny->new($file);
}

sub print ($self, $fh, $msg) :method {
    my $time = Time::Piece->new->strftime("%F %T");
    chomp $msg;
    $fh->print("$time $msg\n");
}

sub running_file ($self) {
    my $dir = $self->c->running_dir;
    eval { Path::Tiny->new($dir)->mkpath };
    die "Cannot mkpath $dir" unless -d $dir;
    my $file = Miniqlo::RunningFile->new("$dir/" . $self->name);
    if ($file->lock(1)) { # timeout 1sec
        $file->write_pid($$);
        $file;
    } else {
        undef;
    }
}
sub is_running ($self) {
    my $name = $self->name;
    my $file = Miniqlo::RunningFile->new($self->c->running_dir . "/$name");
    $file->is_running;
}

sub code ($self) {
    sub {
        my $start_time = Time::Piece->new;
        my $log_file = $self->log_file($start_time);
        my $abs_log_file = Path::Tiny->new($self->c->log_dir, $log_file);
        eval { $abs_log_file->parent->mkpath };
        die "Cannot mkpath @{[$abs_log_file->parent]}" unless $abs_log_file->parent->is_dir;
        my $fh = $abs_log_file->opena;
        $fh->autoflush(1);
        my $running_file = $self->running_file;
        $self->db->insert(history => {
            name => $self->name, start_time => $start_time->epoch,
            log_file => $log_file->path,
            (!$running_file ? (success => 0) : ())
        });
        if (!$running_file) {
            $self->print($fh, "Another cron is running, so exit (mark as fail).");
            return;
        }
        my $pid = open my $pipe, "-|";
        if ($pid == 0) {
            open STDERR, ">&", \*STDOUT;
            open STDIN, "</dev/null";
            exec $self->script;
            exit 255;
        }
        while (my $l = <$pipe>) {
            $self->print($fh, $l);
        }
        close $pipe;
        my $exit = Process::Status->new($?);
        my $row = $self->db->single(history => {
            name => $self->name, start_time => $start_time->epoch,
        });
        if ($row) {
            $row->update({end_time => time, success => $exit->is_success ? 1 : 0});
        } else {
            warn "WHAT TO DO";
        }
        $running_file->unlink;
        exit;
    };
}


1;
