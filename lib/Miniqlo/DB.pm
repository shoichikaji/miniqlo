package Miniqlo::DB;
use Miniqlo::Base;
use parent 'Teng';

package Miniqlo::DB::Schema {
    use Teng::Schema::Declare;
    table {
        name 'history';
        pk qw(name start_time);
        columns qw(name start_time end_time success log_file);
        for my $int (qw(start_time end_time success)) {
            inflate $int => sub { 0 + shift };
        }
    };
    $INC{"Miniqlo/DB/Schema.pm"} = __FILE__;
}

sub new ($class, %option) {
    my $sql = <<'    ...';
    CREATE TABLE IF NOT EXISTS history (
        name       TEXT NOT NULL,
        start_time INT  NOT NULL,
        end_time   INT  DEFAULT 0,
        success    INT  DEFAULT -1,
        log_file    TEXT NOT NULL,
        UNIQUE (name, start_time)
    );
    ...
    $sql =~ s/^[ ]{4}//mg;
    $class->SUPER::new(on_connect_do => $sql, %option);
}

1;
