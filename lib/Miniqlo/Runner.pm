package Miniqlo::Runner;
use Miniqlo::Base;
use Miniqlo::Job;
use Miniqlo::DB;
use Proclet;
use Path::Tiny ();
use Time::Piece ();

sub new ($class) {
    my $self = bless {}, $class;
    my $dbname = $self->base_dir . "/var/history.sqlite";
    $self->{db} = Miniqlo::DB->new(connect_info => ["dbi:SQLite:dbname=$dbname", "", ""]);
    $self;
}
sub db ($self) { $self->{db} }

sub base_dir ($self) {
    $self->{base_dir} ||= Path::Tiny->new($0)->dirname->absolute;
}
sub cron_logfile ($self, $name, $time) {
    my $file = sprintf "%s/log/%s/%s", $self->base_dir, $name,
        $time->strftime("%Y-%m-%d/%H-%M-%s.log");
    Path::Tiny->new($file);
}
sub load_jobs ($self) {
    my $base_dir = $self->base_dir;
    my @file = glob "$base_dir/job/*.yaml $base_dir/job/*.yml $base_dir/job/*.json";
    my @jobs;
    for my $file (@file) {
        push @jobs, Miniqlo::Job->new_from_file($file);
    }
    \@jobs;
}

sub info ($self, $fh, $msg) {
    chomp $msg;
    $fh->print(
        Time::Piece->new->strftime("%F %T ") . $msg . "\n"
    );
}

use Fcntl ':flock';
sub create_running_file ($self, $job_name) {
    my $var_dir = $self->base_dir . "/var/running";
    my $file = "$var_dir/$job_name";
    open my $fh, ">+", $file;
    my $ok = flock $fh, LOCK_EX | LOCK_NB;
    if ($ok) {
        return { fh => $fh, path => $file };
    } else {
        return;
    }
}

sub generate_cron ($self, $job) {
    sub {
        my $start_time = Time::Piece->new;
        my $logfile = $self->cron_logfile($job->name, $start_time);
        eval { $logfile->dirname->mkpath };
        my $fh = $logfile->opena;
        $fh->autoflush(1);
        my $running_file = $self->create_running_file($job->name);
        if (!$running_file) {
            $self->info($fh, "Another cron is running, so exit (mark as fail).");
        }
        $self->db->insert(histroy => {
            name => $job->name, start_time => $start_time->epoch,
            logfile => $logfile->path,
            (!$running_file ? (success => 0) : ())
        });
        return if !$running_file;
        my $pid = open my $pipe, "-|";
        if ($pid == 0) {
            open STDERR, ">&", \*STDOUT;
            open STDIN, "</dev/null";
            exec $job->{script};
            exit 255;
        }
        while (my $l = <$pipe>) {
            $self->info($fh, $l);
        }
        close $pipe;
        my $exit = Process::Status->new($?);
        $self->db->update(history => {
            name => $job->name, start_time => $start_time->epoch,
            end_time => time,
            success => $exit->is_success ? 1 : 0,
        });
        unlink $running_file->{path};
        exit;
    };
}

sub run ($self) {
}


1;
