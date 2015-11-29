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
        row_class "Miniqlo::DB::Row";
    };
    $INC{"Miniqlo/DB/Schema.pm"} = __FILE__;
}
package Miniqlo::DB::Row {
    use parent 'Teng::Row';
    use Time::Piece ();
    sub get_object ($self, $name) {
        unless ($name && $name =~ /time$/) {
            die "Cannot call get_as_object with $name column";
        }
        Time::Piece->new( $self->get($name) );
    }
    sub get_elapsed ($self) {
        my $end = $self->get('end_time');
        return 0 if $end == 0;
        $end - $self->get('start_time');
    }
    $INC{"Miniqlo/DB/Row.pm"} = __FILE__;
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
