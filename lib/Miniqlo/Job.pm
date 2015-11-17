package Miniqlo::Job;
use Miniqlo::Base;
use YAML ();
use JSON ();
use Path::Tiny ();

sub new_from_file ($class, $file) {
    my $path = Path::Tiny->new($file);
    my $self;
    if ($file =~ /\.(yaml|yml)$/n) {
        $self = YAML::Load($path->slurp);
    } elsif ($file =~ /\.json$/n) {
        $self = JSON::decode_json($path->slurp);
    }
    ($self->{name}) = $path->basename =~ /(.+)\.(yaml|yml|json)$/;
    bless $self, $class;
}

sub script ($self) { $self->{script} }
sub name   ($self) { $self->{name}   }
sub every  ($self) { $self->{every}  }

1;
