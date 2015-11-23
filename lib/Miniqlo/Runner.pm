package Miniqlo::Runner;
use Miniqlo::Base;
use Miniqlo::Web;
use Miniqlo;

use Proclet;
use Plack::Loader;
use JSON::PP ();
use Getopt::Long qw(:config no_auto_abbrev no_ignore_case bundling);

sub new ($class) { bless {}, $class }
sub c ($self) { Miniqlo->context || Miniqlo->bootstrap }
sub host ($self) { $self->{host} }
sub port ($self) { $self->{port} }
sub log_ttl ($self) { $self->{log_ttl} }
sub parse_options ($self, @argv) {
    local @ARGV = @argv;
    GetOptions
        "c|config=s"    => \my $config_file,
        "p|port=i"      => \my $port,
        "host=s"        => \my $host,
        "base_dir=s"    => \my $base_dir,
        "d|daemonize"   => \my $daemonize,
        "log_ttl_day=i" => \my $log_ttl_day,
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
    $self->{log_ttl_day} = $log_ttl_day || $config->{log_ttl_day} || 14;
    $self->{daemonize}   = $daemonize   || $config->{daemonize}   || 0;
    $self->{log_ttl}     = $self->{log_ttl_day} * 24 * 60 * 60;
    $base_dir ||= $config->{base_dir} || ".";
    if ($base_dir =~ s{^\./}{}) {
        die "Cannot use ./ notation in command argument.\n" unless -f $config_file;
        $base_dir = Path::Tiny->new($config_file)->parent->child($base_dir);
    }
    $base_dir = Path::Tiny->new($base_dir)->absolute->stringify;
    { no warnings; *Miniqlo::base_dir = sub { $base_dir } }
    @ARGV;
}
sub run ($self, @argv) {
    $self = $self->new unless ref $self;
    @argv = $self->parse_options(@argv);
    my $proclet = $self->_proclet;
}

sub _cleaner ($self) {
    my $log_dir = $self->c->log_dir;
    my $now = time;
    my $deleted = 0;
    sub {
        Path::Tiny->new($log_dir)->visit(
            sub {
                my $path = shift;
                return unless $path->is_file;
                my $stat = $path->stat;
                if ($now - $stat->mtime > $self->log_ttl) {
                    eval { $path->remove };
                    if ($@) {
                        warn "Failed to unlink $path: $@\n";
                    } else {
                        $deleted++;
                    }
                }
            },
            { recursive => 1},
        );
        warn "Deleted $deleted log files.\n";
    };
}

sub _proclet ($self) {
    my $proclet = Proclet->new;
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
