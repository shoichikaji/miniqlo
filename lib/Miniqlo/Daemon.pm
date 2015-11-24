package Miniqlo::Daemon;
use Miniqlo::Base;
use Miniqlo;
use parent 'Daemon::Control';

sub new ($class, %option) {
    $class->SUPER::new(
        name         => "miniqlo",
        kill_timeout => 300,
        stop_signals => ['TERM'],
        pid_file     => $class->c->base_dir . "/var/miniqlo.pid",
        stdout_file  => $class->c->base_dir . "/var/miniqlo.out",
        stderr_file  => $class->c->base_dir . "/var/miniqlo.out",
        fork         => 2,
        %option,
    );
}

sub c ($self) { Miniqlo->context || Miniqlo->bootstrap }

sub runnig_cron ($self) {
    map { $_->is_running } $self->c->load_cron;
}

sub do_stop ($self) {
    $self->read_pid;
    my $start_pid = $self->pid;

    # Probably don't want to send anything to init(1).
    return 1 unless $start_pid > 1;

    if ( $self->pid_running($start_pid) ) {
        my $signal = 'TERM';
        $self->trace( "Sending $signal signal to pid $start_pid..." );
        kill $signal => $start_pid;

        my $sleeped = 0;
        for (1..$self->kill_timeout) {
            # abort early if the process is now stopped
            $self->trace("checking if pid $start_pid is still running...");
            last if not $self->pid_running($start_pid);
            sleep 1;
            if (++$sleeped % 10 == 0) {
                if (my @running = $self->runnig_cron) {
                    $self->pretty_print("Still running: " . join(", ", @running));
                } else {
                    $self->pretty_print("Something wrong...");
                }
            }
        }
        if ( $self->pid_running($start_pid) ) {
            $self->pretty_print( "Failed to Stop", "red" );
            return 1;
        }
        $self->pretty_print( "Stopped" );
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
