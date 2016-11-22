package B::UNOP;

use strict;

use B::C::Config;
use B::C::File qw/unopsect init/;
use B::C::Helpers qw/do_labels mark_package padop_name svop_name curcv/;

sub do_save {
    my ( $op, $level ) = @_;

    $level ||= 0;

    unopsect()->comment_common("first");
    my $ix = unopsect()->sadd( "%s, s\\_%x", $op->_save_common, ${ $op->first } );
    unopsect()->debug( $op->name, $op );

    if ( $op->name eq 'method' and $op->first and $op->first->name eq 'const' ) {
        my $method = svop_name( $op->first );

        #324,#326 need to detect ->(maybe::next|maybe|next)::(method|can)
        if ( $method =~ /^(maybe::next|maybe|next)::(method|can)$/ ) {
            debug( pkg => "mark \"$1\" for method $method" );
            mark_package( $1,    1 );
            mark_package( "mro", 1 );
        }    # and also the old 5.8 NEXT|EVERY with non-fixed method names und subpackages
        elsif ( $method =~ /^(NEXT|EVERY)::/ ) {
            debug( pkg => "mark \"$1\" for method $method" );
            mark_package( $1, 1 );
            mark_package( "NEXT", 1 ) if $1 ne "NEXT";
        }
    }
    do_labels( $op, $level + 1, 'first' );

    return "(OP*)&unop_list[$ix]";
}

1;
