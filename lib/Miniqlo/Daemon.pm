package Miniqlo::Daemon;
use Miniqlo::Base;
use Miniqlo;
use parent 'Daemon::Control';

sub new ($class, %option) {
    $class->SUPER::new(
        name         => "miniqlo",
        pid_file     => $class->c->base_dir . "/var/daemon.pid",
        stdout_file  => $class->c->base_dir . "/var/daemon.out",
        stderr_file  => $class->c->base_dir . "/var/daemon.out",
        fork         => 2,
        %option,
    );
}

sub c ($self) { Miniqlo->context || Miniqlo->bootstrap }

sub pretty_print ($self, $msg, @) {
    warn "$msg\n";
}

sub do_start ($self, @arg) {
    my $exit = $self->SUPER::do_start(@arg);
    return $exit if $exit != 0;
    sleep 5;
    $self->read_pid;
    if ($self->pid && $self->pid_running) {
        return 0;
    } else {
        $self->prettry_print("ERROR miniqlo exit too immediately");
        return 1;
    }
}

sub do_stop ($self, @) {
    $self->read_pid;
    my $start_pid = $self->pid;

    # Probably don't want to send anything to init(1).
    return 1 unless $start_pid > 1;

    if ( $self->pid_running($start_pid) ) {
        $self->pretty_print("Stopping miniqlo (pid=$start_pid)");
        kill TERM => $start_pid;

        my ($sleeped, $cron_stopped) = (0, 0);
        for (1..900) {
            my @running_cron = $self->c->running_cron;
            if (!@running_cron) {
                $cron_stopped++;
                last;
            }
            if (++$sleeped % 10 == 0) {
                my $msg = join ", ", map {
                    my ($pid, $name)  = ($_->{pid}, $_->{name});
                    "$name (pid=$pid)";
                } @running_cron;
                $self->pretty_print("Still running cron $msg");
            }
            sleep 1;
        }
        my $main_stopped;
        if ($cron_stopped) {
            for (1..10) {
                if (!$self->pid_running($start_pid)) {
                    $main_stopped++;
                    last;
                } else {
                    sleep 1;
                }
            }
        }
        if ($cron_stopped && $main_stopped) {
            $self->pretty_print("Successfully stopped");
        } else {
            $self->pretty_print("Failed to stop");
            return 1;
        }
    } else {
        $self->pretty_print("Not Running", "red");
    }
    if ( $self->pid_file ) {
        unlink($self->pid_file) if $self->read_pid == $start_pid;
    }
    return 0;
}


1;
