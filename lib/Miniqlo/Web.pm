package Miniqlo::Web;
use Miniqlo::Base;
use Miniqlo::Web::Dispatcher;
use parent qw(Miniqlo Amon2::Web);

sub dispatch {
    return (Miniqlo::Web::Dispatcher->dispatch($_[0]) or die "response is not generated");
}

__PACKAGE__->load_plugin('Web::JSON', {canonical => 1});
__PACKAGE__->add_trigger(
    AFTER_DISPATCH => sub ($c, $res, @) {
        $res->header( 'X-Content-Type-Options' => 'nosniff' );
        $res->header( 'X-Frame-Options' => 'DENY' );
        $res->header( 'Cache-Control' => 'private' );
    },
);

use Plack::Builder;
use Plack::App::File;
sub to_app ($self) {
    my $app = $self->SUPER::to_app;
    my $file = Plack::App::File->new(root => $self->base_dir . "/assets/src/")->to_app;
    builder {
        enable 'DirIndex';
        enable 'Static', path => sub { s{^/cron/_log/}{} }, root => $self->log_dir . "/";
        mount "/cron" => $app;
        mount "/" => $file;
    };
}

sub render_csv ($self, $body) {
    my $res = $self->create_response(200);
    if (ref $body) {
        $body = join("\n", map { join ",", $_->@* } $body->@*) . "\n";
    }
    $res->content_type("text/csv; charset=utf-8");
    $res->content_length(length $body);
    $res->body($body);
    $res;
}

1;
