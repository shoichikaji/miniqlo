package Miniqlo::Daemon;
use Miniqlo::Base;
use Miniqlo;
use parent 'Daemon::Control';

sub new ($class, %option) {
    $class->SUPER::new(
        name         => "miniqlo",
        kill_timeout => 30,
        stop_signals => ['TERM'],
        pid_file     => $class->c->base_dir . "/var/miniqlo.pid",
        stdout_file  => $class->c->base_dir . "/var/miniqlo.out",
        stderr_file  => $class->c->base_dir . "/var/miniqlo.out",
        fork         => 2,
        %option,
    );
}

sub c ($self) { Miniqlo->context || Miniqlo->bootstrap }

sub pretty_print ($self, $msg, @) {
    warn "-> $msg\n";
}

sub do_stop ($self) {
    $self->read_pid;
    my $start_pid = $self->pid;

    # Probably don't want to send anything to init(1).
    return 1 unless $start_pid > 1;

    if ( $self->pid_running($start_pid) ) {
        my $signal = 'TERM';
        kill $signal => $start_pid;

        # for (1..$self->kill_timeout) {
        #     # abort early if the process is now stopped
        #     $self->trace("checking if pid $start_pid is still running...");
        #     last if not $self->pid_running($start_pid);
        #     sleep 1;
        # }
        # if ( $self->pid_running($start_pid) ) {
        #     $self->pretty_print( "Failed to Stop", "red" );
        #     return 1;
        # }
        my $sleeped = 0;
        my $cron_stopped;
        for (1..300) {
            my @running_cron = $self->c->running_cron;
            if (!@running_cron) {
                $cron_stopped++;
                last;
            }
            if (++$sleeped % 1 == 0) {
                my $msg = join ", ", map {
                    my ($pid, $name)  = ($_->{pid}, $_->{name});
                    "$name (pid=$pid)";
                } @running_cron;
                $self->pretty_print("Still running $msg");
            }
            sleep 1;
        }
        if ($cron_stopped) {
            for (1..10) {
                if (!$self->pid_running($start_pid)) {
                    $self->pretty_print("Stop OK");
                    return 0;
                } else {
                    sleep 1;
                }
            }
        }
        $self->pretty_print("Failed to stop");
        return 1;
    } else {
        $self->pretty_print( "Not Running", "red" );
    }

    # Clean up the PID file on stop, unless the pid
    # doesn't match $start_pid (perhaps a standby
    # worker stepped in to take over from the one
    # that was just terminated).

    if ( $self->pid_file ) {
      unlink($self->pid_file) if $self->read_pid == $start_pid;
    }
    return 0;
}


1;
