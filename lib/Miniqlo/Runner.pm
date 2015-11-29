package Miniqlo::Runner;
use Miniqlo::Base;
use Miniqlo::Web;
use Miniqlo::Daemon;
use Miniqlo;

use Daemon::Control;
use Getopt::Long qw(:config no_auto_abbrev no_ignore_case bundling);
use JSON::PP ();
use Plack::Loader;
use Proclet;
use Try::Tiny;
use Time::Piece ();
use File::RotateLogs;
use Pod::Usage ();

sub new ($class) { bless {}, $class }
sub c ($self) { Miniqlo->context || Miniqlo->bootstrap }
sub base_dir ($self) { $self->c->base_dir }
sub host ($self) { $self->{host} }
sub port ($self) { $self->{port} }
sub max_workers ($self) { $self->{max_workers} }
sub log_ttl ($self) { $self->{log_ttl} }
sub daemonize ($self) { $self->{daemonize} }
sub parse_options ($self, @argv) {
    local @ARGV = @argv;
    GetOptions
        "c|config=s"    => \my $config_file,
        "p|port=i"      => \my $port,
        "max_workers=i" => \my $max_workers,
        "host=s"        => \my $host,
        "base_dir=s"    => \my $base_dir,
        "d|daemonize"   => \my $daemonize,
        "log_ttl_day=i" => \my $log_ttl_day,
        "h|help"        => sub { Pod::Usage::pod2usage(1) },
    or exit 1;
    my $config = +{};
    if ($config_file) {
        my $content = do {
            open my $fh, "<", $config_file or die "open $config: $!"; local $/; <$fh>;
        };
        $config = JSON::PP->new->decode($content);
    }
    $config->{web} ||= +{};
    $self->{port}        = $port        || $config->{web}{port}        || 5000;
    $self->{host}        = $host        || $config->{web}{host}        || '0.0.0.0';
    $self->{max_workers} = $max_workers || $config->{web}{max_workers} || 10;
    $self->{log_ttl_day} = $log_ttl_day || $config->{log_ttl_day}      || 14;
    $self->{daemonize}   = $daemonize   || $config->{daemonize}        || 0;
    $self->{log_ttl}      = $self->{log_ttl_day} * 24 * 60 * 60;
    $base_dir ||= $config->{base_dir} || ".";
    if ($base_dir =~ s{^\./}{}) {
        die "Cannot use ./ notation in command argument.\n" unless -f $config_file;
        $base_dir = Path::Tiny->new($config_file)->parent->child($base_dir || ".");
    }
    $base_dir = Path::Tiny->new($base_dir)->absolute->stringify;
    { no warnings qw(once redefine); *Miniqlo::base_dir = sub { $base_dir } }
    @ARGV;
}
sub run ($self, @argv) {
    $self = $self->new unless ref $self;
    @argv = $self->parse_options(@argv);
    my $subcmd = shift @argv || "start";
    $subcmd eq "help" and Pod::Usage::pod2usage(1);
    my %valid = (start => 1, stop => 1, restart => 1, status => 1, help => 1);
    $valid{$subcmd} or die "Unknown subcommand '$subcmd'\n";

    local $Log::Minimal::PRINT = sub {
        my ($time, $type, $message, $trace, $raw_message) = @_;
        $message =~ s/(?:\\n)+$//;
        warn "$type $message\n";
    };
    if ($self->daemonize) {
        my $dir = $self->c->log_dir . "/_miniqlo";
        Path::Tiny->new($dir)->mkpath unless -d $dir;
        my $rotate = File::RotateLogs->new(
            logfile  => "$dir/%Y%m%d.log",
            linkname => "$dir/latest.log",
            rotationtime => 24*60*60,
            maxage => 0,
            offset => 0 + ("" . Time::Piece->localtime->tzoffset),
        );
        my $proclet = $self->_proclet(sub { $rotate->print(@_) });
        my $daemon = $self->daemon(sub {
            $proclet->run;
            my $term = 0;
            local $SIG{TERM} = sub { $term++ };
            my $logging = sub {
                my $msg = shift;
                my $time = Time::Piece->new->strftime("%H:%M:%S");
                $rotate->print($time . (" " x 12) . "| $msg\n");
            };
            $logging->("INFO Catch signal TERM, try to shutdown...");
            my $times = 0;
            while (1) {
                if ($term) {
                    $logging->("WARN Catch another signal TERM, try to shutdown...");
                    $term = 0;
                }
                my @running_cron = $self->c->running_cron;
                last unless @running_cron;
                if (++$times % 1 == 0) {
                    my $msg = join ", ", map {
                        my ($pid, $name)  = ($_->{pid}, $_->{name});
                        "$name (pid=$pid)";
                    } @running_cron;
                    $logging->("INFO Still running $msg");
                }
                sleep 1;
            }
            $logging->("INFO All cron are finished, successfully shutdown\n");
        });
        exit $daemon->run_command($subcmd);
    } elsif ($subcmd eq "start") {
        my $proclet = $self->_proclet;
        $proclet->run;
    } else {
        die "Cannot use '$subcmd' in non daemonize mode\n";
    }
}

sub daemon ($self, $program) {
    Miniqlo::Daemon->new(program => $program),
}

sub _cleaner ($self) {
    my $log_dir = Path::Tiny->new($self->c->log_dir);
    sub {
        my $now = time;
        my $deleted = 0;
        my @to_be_removed;
        $log_dir->visit(
            sub {
                my $path = shift;
                my $stat = $path->stat;
                return unless $now - $stat->mtime > $self->log_ttl;
                if ($path->is_dir) {
                    push @to_be_removed, $path;
                } else {
                    try {
                        $path->remove;
                        $deleted++;
                    } catch {
                        warn "Failed to unlink $path: $@\n";
                    };
                }
            },
            { recursive => 1},
        );
        for my $dir (@to_be_removed) {
            rmdir $dir; # don't check
        }
        warn "Deleted $deleted log files.\n";
    };
}

sub _proclet ($self, $logger = undef) {
    my $proclet = Proclet->new( $logger ? (logger => $logger) : () );
    for my $cron ($self->c->load_cron) {
        $proclet->service(
            tag => $cron->name,
            every => $cron->every,
            code => $cron->code,
        );
    }
    $proclet->service(
        tag => '_web',
        code => sub {
            { no warnings 'once'; undef $Minialo::CONTEXT }
            my $app = Miniqlo::Web->to_app;
            my $loader = Plack::Loader->load(
                'Starlet', port => $self->port, host => $self->host,
                max_workers => $self->max_workers,
            );
            $loader->run($app);
        },
    );
    $proclet->service(
        tag   => '_cleaner',
        every => '2 8,20 * * *',
        code  => $self->_cleaner,
    );
    $proclet;
}

1;
