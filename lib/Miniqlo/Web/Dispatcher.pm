package Miniqlo::Web::Dispatcher;
use Miniqlo::Base;
use Amon2::Web::Dispatcher::RouterBoom;
use Data::Dump;

get '_all.json' => sub ($c, @) {
    my @cron = $c->load_cron;
    my @out;
    for my $cron (@cron) {
        my ($latest, $next) = $c->db->search(
            'history', {name => $cron->name}, {order_by => 'start_time DESC', limit => 2},
        );
        my $is_running = $cron->is_running;
        my ($success, $start_time)
            =  $is_running && $next ? ($next->get('success'), $next->get('start_time'))
            :  $latest              ? ($latest->get('success'), $latest->get('start_time'))
            :                         (-1, 0);
        push @out, {
            name       => $cron->name,
            is_running => $is_running,
            success    => $success,
        };
    }
    $c->render_json(\@out);
};

get ':name.json' => sub ($c, $arg, @) {
    my ($cron) = grep { $_->name eq $arg->{name} } $c->load_cron;
    if (!$cron) {
        my $res = $c->render_json([]);
        $res->status(404);
        return $res;
    }
    my @rows = $c->db->search('history'
        => { name => $cron->name }
        => { order_by => 'start_time DESC', limit => 20},
    );
    $c->render_json([
        map +{
            start_time => $_->get('start_time'),
            log_file   => "/cron/_log/" . $_->get('log_file'),
            success    => $_->get('success'),
            end_time   => $_->get('end_time'),
        }, @rows
    ]);
};

get ':name/timeseries.csv' => sub ($c, $arg, @) {
    my ($cron) = grep { $_->name eq $arg->{name} } $c->load_cron;
    if (!$cron) {
        my $res = $c->render_csv("");
        $res->status(404);
        return $res;
    }
    my @rows = $c->db->search('history'
        => { name => $cron->name },
        => { order_by => 'start_time DESC', limit => 200 },
    );
    my @csv = (["date,elapsed"]);
    for my $row (reverse @rows) {
        my $date = $row->get_object('start_time')->strftime("%Y/%m/%d %H:%M:%S");
        my $elapsed = $row->get_elapsed || "";
        push @csv, [$date, $elapsed];
    }
    $c->render_csv(\@csv);
};

1;
