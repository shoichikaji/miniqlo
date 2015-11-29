package Miniqlo::Web::Dispatcher;
use Miniqlo::Base;
use Amon2::Web::Dispatcher::RouterBoom;
use Data::Dump;

get '/' => sub ($c, @) {
    my @cron = $c->load_cron;
    my @out;
    for my $cron (@cron) {
        my $latest = $c->db->single(
            'history', {name => $cron->name}, {order_by => 'start_time DESC'},
        );
        push @out, {
            name => $cron->name, is_running => $cron->is_running,
            $latest ? (latest => $latest->get('start_time')) : (),
        };
    }
    $c->render_json(\@out);
};

get '/cron/:name' => sub ($c, $arg, @) {
    my ($cron) = grep { $_->name eq $arg->{name} } $c->load_cron;
    if (!$cron) {
        my $res = $c->render_json([]);
        $res->status(404);
        return $res;
    }
    my @rows = $c->db->search('history' => {name => $cron->name}, {order_by => 'start_time'});
    $c->render_json([
        map +{
            start_time => $_->get('start_time'),
            log_file   => $_->get('log_file'),
            success    => $_->get('success'),
            end_time   => $_->get('end_time'),
        }, @rows
    ]);
};

1;
