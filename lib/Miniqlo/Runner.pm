package Miniqlo::Runner;
use Miniqlo::Base;
use Miniqlo::Web;
use Miniqlo;

use Daemon::Control;
use Getopt::Long qw(:config no_auto_abbrev no_ignore_case bundling);
use JSON::PP ();
use Plack::Loader;
use Proclet;
use Try::Tiny;
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
    $self->{port}        = $port        || $config->{web}{port}   || 5000;
    $self->{host}        = $host        || $config->{web}{host}   || '0.0.0.0';
    $self->{max_workers} = $max_workers || $config->{web}{max_workers} || 10;
    $self->{log_ttl_day} = $log_ttl_day || $config->{log_ttl_day} || 14;
    $self->{daemonize}   = $daemonize   || $config->{daemonize}   || 0;
    $self->{log_ttl}     = $self->{log_ttl_day} * 24 * 60 * 60;
    $base_dir ||= $config->{base_dir} || ".";
    if ($base_dir =~ s{^\./}{}) {
        die "Cannot use ./ notation in command argument.\n" unless -f $config_file;
        $base_dir = Path::Tiny->new($config_file)->parent->child($base_dir);
    }
    $base_dir = Path::Tiny->new($base_dir)->absolute->stringify;
    { no warnings qw(once redefine); *Miniqlo::base_dir = sub { $base_dir } }
    @ARGV;
}
sub run ($self, @argv) {
    $self = $self->new unless ref $self;
    @argv = $self->parse_options(@argv);
    my $subcmd = shift @argv or die "Need subcommand, try `$0 --help`\n";
    my %valid = (start => 1, stop => 1, restart => 1, help => 1);
    $valid{$subcmd} or die "Unknown subcommand '$subcmd'\n";
    $subcmd eq "help" and Pod::Usage::pod2usage(1);

    my $logger;
    if ($self->daemonize) {
        my $rotate = File::RotateLogs->new(
            logfile  => $self->c->log_dir . "/_miniqlo/%Y%m%d.log",
            linkname => $self->c->log_dir . "/_miniqlo/latest.log",
            rotationtime => 24*60*60,
            maxage => 0,
            offset => Time::Piece->localtime->tzoffset,
        );
        $logger = sub { $logger->print(@_) };
    }
    my $proclet = $self->_proclet($logger ? (logger => $logger) : ());
}

sub daemon_control ($self, $program) {
    Daemon::Control->new(
        name => $0,
        kill_timeout => 300,
        stop_signals => ['TERM'],
        program => $program,
        pid_file => $self->base_dir . "/var/miniqlo.pid",
        stdout_file => $self->base_dir . "/var/miniqlo.out",
        stderr_file => $self->base_dir . "/var/miniqlo.out",
        fork => 2,
    );
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
