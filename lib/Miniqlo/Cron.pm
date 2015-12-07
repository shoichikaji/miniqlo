package Miniqlo::Cron;
use Miniqlo::Base;
use Miniqlo::RunningFile;
use YAML::Loader;
use JSON::PP ();
use Path::Tiny ();
use Process::Status;
use Scalar::Util ();
use POSIX ();

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
    $hash->{c} = $c;
    $hash->{file} = $file->stringify;
    Scalar::Util::weaken($hash->{c});
    bless $hash, $class;
}

sub file   ($self) { $self->{file}   }
sub script ($self) { $self->{script} }
sub name   ($self) { $self->{name}   }
sub every  ($self) { $self->{every}  }
sub user   ($self) { $self->{user}   }
sub group  ($self) { $self->{group}  }

sub uid ($self) {
    return unless $self->user;
    $self->{uid} //= do {
        my $uid = getpwnam $self->user or die;
        $uid;
    };
}
sub gid ($self) {
    return if !$self->group && !$self->user;
    $self->{gid} //= do {
        if (my $group = $self->group) {
            my $gid = getgrnam $self->group or die;
            $gid;
        } else {
            my $gid = (getpwuid $self->uid)[3];
            $gid;
        }
    };
}

sub validate ($self) {
    my @error;
    push @error, "missing script" unless $self->script;
    push @error, "missing every" unless $self->every;
    push @error, "name cannot be started with '_'" if $self->name =~ /^_/;
    my $is_root = $< == 0;
    if (!$is_root and ($self->user || $self->group)) {
        push @error, "cannot use neither 'user' nor 'group' unless running as root";
    }
    if (my $group = $self->group) {
        my $gid = getgrnam $self->group;
        if (defined $gid) {
            $self->{gid} = $gid;
        } else {
            push @error, "invalid group '$group'";
        }
    }
    if (my $user = $self->user) {
        my $uid = getpwnam $self->user;
        if (defined $uid) {
            $self->{uid} = $uid;
        } else {
            push @error, "invalid user '$user'";
        }
    }
    if (@error) {
        return join ", ", @error;
    } else {
        return;
    }
}

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
        $0 = "miniqlo cron @{[$self->name]}";
        my $start_time = Time::Piece->new;
        my $log_file = $self->log_file($start_time);
        my $abs_log_file = Path::Tiny->new($self->c->log_dir, $log_file);
        eval { $abs_log_file->parent->mkpath };
        die "Cannot mkpath @{[$abs_log_file->parent]}" unless $abs_log_file->parent->is_dir;
        my $fh = $abs_log_file->opena;
        $fh->autoflush(1);
        my $running_file = $self->running_file;
        my $row = $self->db->insert(history => {
            name => $self->name, start_time => $start_time->epoch,
            log_file => $log_file->path,
            (!$running_file ? (success => 0) : ())
        });
        if (!$running_file) {
            my $msg = "WARN Another cron is running, so exit (mark as fail)";
            $self->print($fh, $msg);
            warn "$msg\n";
            $row->update({end_time => time, success => 0});
            return;
        }
        my $pid = open my $pipe, "-|";
        if ($pid == 0) {
            if (defined $self->gid) {
                POSIX::setgid($self->gid) or die "Cannot setgid @{[$self->gid]}: $!";
            }
            if (defined $self->uid) {
                POSIX::setuid($self->uid) or die "Cannot setuid @{[$self->uid]}: $!";
                $ENV{USER} = $self->user;
                $ENV{HOME} = (getpwuid $self->uid)[7];
            }
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
        $row->update({end_time => time, success => $exit->is_success ? 1 : 0});
        $running_file->unlink;
        exit;
    };
}


1;
