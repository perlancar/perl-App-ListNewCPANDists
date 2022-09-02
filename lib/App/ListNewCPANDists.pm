package App::ListNewCPANDists;

use 5.010001;
use strict;
use warnings;
use Log::ger;

# AUTHORITY
# DATE
# DIST
# VERSION

our %SPEC;

my $sch_date = ['date*', 'x.perl.coerce_to' => 'DateTime', 'x.perl.coerce_rules'=>['From_str::natural']];
my $URL_PREFIX = 'https://fastapi.metacpan.org/v1';

our $db_schema_spec = {
    summary => __PACKAGE__,
    latest_v => 2,
    install => [
        'CREATE TABLE dist (
            name TEXT NOT NULL PRIMARY KEY,
            first_version TEXT NOT NULL,
            first_time INTEGER NOT NULL,
            latest_version TEXT NOT NULL,
            latest_time INTEGER NOT NULL,
            mtime INTEGER NOT NULL
        )',
    ],
    install_v1 => [
        'CREATE TABLE release (
            name TEXT NOT NULL PRIMARY KEY,
            dist TEXT NOT NULL,
            time INTEGER NOT NULL
        )',
        'CREATE UNIQUE INDEX ix_release__dist ON release(name,dist)',
    ],
    upgrade_to_v2 => [
        'DROP TABLE release',
        'CREATE TABLE dist (
            name TEXT NOT NULL PRIMARY KEY,
            first_version TEXT NOT NULL,
            first_time INTEGER NOT NULL,
            latest_version TEXT NOT NULL,
            latest_time INTEGER NOT NULL,
            mtime INTEGER NOT NULL
        )',
    ],
};

our %args_common = (
    cpan => {
        summary => 'Location of your local CPAN mirror, e.g. /path/to/cpan',
        schema => 'dirname*',
        description => <<'_',

Defaults to `~/cpan`. This actually does not need to be a real CPAN local
mirror, but can be just an empty directory. If you use happen to use
<pm:App::lcpan>, you can use the local CPAN mirror generated by <prog:lcpan>
(which also defaults to `~/cpan`) to store the database.

_
        tags => ['common'],
    },
    db_name => {
        summary => 'Filename of database',
        schema =>'filename*',
        default => 'index-lncd.db',
    },
);

our %args_filter = (
    exclude_dists => {
        'x.name.is_plural' => 1,
        'x.name.singular' => 'exclude_dist',
        schema => ['array*', of=>'perl::distname*'],
        tags => ['category:filtering'],
    },
    exclude_dist_re => {
        schema => 're*',
        tags => ['category:filtering'],
    },
    include_dists => {
        'x.name.is_plural' => 1,
        'x.name.singular' => 'exclude_dist',
        schema => ['array*', of=>'perl::distname*'],
        tags => ['category:filtering'],
    },
    include_dist_re => {
        schema => 're*',
        tags => ['category:filtering'],
    },
    exclude_authors => {
        'x.name.is_plural' => 1,
        'x.name.singular' => 'exclude_author',
        schema => ['array*', of=>'cpan::pause_id*'],
        tags => ['category:filtering'],
    },
    exclude_author_re => {
        schema => 're*',
        tags => ['category:filtering'],
    },
    include_authors => {
        'x.name.is_plural' => 1,
        'x.name.singular' => 'include_author',
        schema => ['array*', of=>'cpan::pause_id*'],
        tags => ['category:filtering'],
    },
    include_author_re => {
        schema => 're*',
        tags => ['category:filtering'],
    },
);

sub _json_encode {
    require JSON;
    JSON->new->encode($_[0]);
}

sub _json_decode {
    require JSON;
    JSON->new->decode($_[0]);
}

sub _create_schema {
    require SQL::Schema::Versioned;

    my $dbh = shift;

    my $res = SQL::Schema::Versioned::create_or_update_db_schema(
        dbh => $dbh, spec => $db_schema_spec);
    die "Can't create/update schema: $res->[0] - $res->[1]\n"
        unless $res->[0] == 200;
}

sub _db_path {
    my ($cpan, $db_name) = @_;
    "$cpan/$db_name";
}

sub _connect_db {
    require DBI;

    my ($cpan, $db_name) = @_;

    my $db_path = _db_path($cpan, $db_name);
    log_trace("Connecting to SQLite database at %s ...", $db_path);
    my $dbh = DBI->connect("dbi:SQLite:dbname=$db_path", undef, undef,
                           {RaiseError=>1});
    #$dbh->do("PRAGMA cache_size = 400000"); # 400M
    _create_schema($dbh);
    $dbh;
}

sub _set_args_default {
    my $args = shift;
    if (!$args->{cpan}) {
        require File::HomeDir;
        my $homedir = File::HomeDir->my_home;
        if (-d "$homedir/cpan") {
            $args->{cpan} =  "$homedir/cpan";
        } else {
            $args->{cpan} = $homedir;
        }
    }
    $args->{db_name} //= 'index-lncd.db';
}

sub _init {
    my ($args) = @_;

    unless ($App::ListNewCPANDists::state) {
        _set_args_default($args);
        my $state = {
            dbh => _connect_db($args->{cpan}, $args->{db_name}),
            cpan => $args->{cpan},
            db_name => $args->{db_name},
        };
        $App::ListNewCPANDists::state = $state;
    }
    $App::ListNewCPANDists::state;
}

sub _http_tiny {
    state $obj = do {
        require HTTP::Tiny;
        HTTP::Tiny->new;
    };
    $obj;
}

sub _get_dist_release_times {
    require Time::Local;

    my ($state, $dist) = @_;

    # save an API call if we can find a cache in database
    my $dbh = $state->{dbh};
    my ($distinfo) = $dbh->selectrow_hashref(
        "SELECT * FROM dist WHERE name=?",
        {},
        $dist,
    );
    return $distinfo if $distinfo && $distinfo->{mtime} >= time() - 8*3600; # cache for 8 hours
    my $row_exists = $distinfo ? 1:0;

    # find first release time & version
    unless ($distinfo) {
        my $res = _http_tiny->post("$URL_PREFIX/release/_search?size=1&sort=date", {
            content => _json_encode({
                query => {
                    terms => {
                        distribution => [$dist],
                    },
                },
                fields => [qw/name date version version_numified/],
            }),
        });

        die "Can't retrieve first release information of distribution '$dist': ".
            "$res->{status} - $res->{reason}\n" unless $res->{success};
        my $api_res = _json_decode($res->{content});
        my $hit = $api_res->{hits}{hits}[0];
        die "No release information for distribution '$dist'" unless $hit;
        $hit->{fields}{date} =~ /^(\d\d\d\d)-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)/
            or die "Can't parse date '$hit->{fields}{date}'";
        my $time = Time::Local::timegm($6, $5, $4, $3, $2-1, $1);
        $distinfo = {
            name => $dist,
            first_time => $time,
            first_version => $hit->{fields}{version},
        };
    }

    # find latest release time & version
    {
        my $res = _http_tiny->post("$URL_PREFIX/release/_search?size=1&sort=date:desc", {
            content => _json_encode({
                query => {
                    terms => {
                        distribution => [$dist],
                    },
                },
                fields => [qw/name date version version_numified/],
            }),
        });

        die "Can't retrieve latest release information of distribution '$dist': ".
            "$res->{status} - $res->{reason}\n" unless $res->{success};
        my $api_res = _json_decode($res->{content});
        my $hit = $api_res->{hits}{hits}[0];
        die "No release information for distribution '$dist'" unless $hit;
        $hit->{fields}{date} =~ /^(\d\d\d\d)-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)/
            or die "Can't parse date '$hit->{fields}{date}'";
        my $time = Time::Local::timegm($6, $5, $4, $3, $2-1, $1);
        $distinfo->{latest_time} = $time;
        $distinfo->{latest_version} = $hit->{fields}{version};
    }

    # cache to database
    if ($row_exists) {
        $dbh->do("UPDATE dist SET first_version=?,first_time=?,latest_version=?,latest_time=?, mtime=? WHERE name=?", {},
                 $distinfo->{first_version}, $distinfo->{first_time}, $distinfo->{latest_version}, $distinfo->{latest_time},
                 time(),
                 $distinfo->{name},
             );
    } else {
        $dbh->do("INSERT INTO dist (name,first_version,first_time,latest_version,latest_time, mtime) VALUES (?,?,?,?,?, ?)", {},
                 $distinfo->{name}, $distinfo->{first_version}, $distinfo->{first_time}, $distinfo->{latest_version}, $distinfo->{latest_time},
                 time(),
             );
    }
    $distinfo;
}

$SPEC{list_new_cpan_dists} = {
    v => 1.1,
    summary => 'List new CPAN distributions in a given time period',
    description => <<'_',

This utility queries MetaCPAN to find out what CPAN distributions are new in a
given time period (i.e. has their first release made during that time period).
This utility also collects the information in a SQLite database which defaults
to `~/cpan/index-lncd.db` or `~/index-lncd.db` if `~/cpan~` does not exist. You
can customize the location of the generated SQLite database using the `cpan` and
`db_name` arguments.

_
    args => {
        %args_common,
        %args_filter,
        from_time => {
            schema => $sch_date,
            pos => 0,
            cmdline_aliases => {from=>{}},
            tags => ['category:time-filtering'],
        },
        to_time   => {
            schema => $sch_date,
            pos => 1,
            cmdline_aliases => {to=>{}},
            tags => ['category:time-filtering'],
        },

        today => {
            schema => 'true*',
            tags => ['category:time-filtering'],
        },
        this_week => {
            schema => 'true*',
            description => <<'_',

Monday is the start of the week.

_
            tags => ['category:time-filtering'],
        },
        this_month => {
            schema => 'true*',
            tags => ['category:time-filtering'],
        },
        this_year => {
            schema => 'true*',
            tags => ['category:time-filtering'],
        },
        yesterday => {
            schema => 'true*',
            tags => ['category:time-filtering'],
        },
        last_week => {
            schema => 'true*',
            description => <<'_',

Monday is the start of the week.

_
            tags => ['category:time-filtering'],
        },
        last_month => {
            schema => 'true*',
            tags => ['category:time-filtering'],
        },
        last_year => {
            schema => 'true*',
            tags => ['category:time-filtering'],
        },
    },
    args_rels => {
        req_one => [qw/today this_week this_month this_year yesterday last_week last_month last_year from_time/],
    },
    examples => [
        {
            summary => 'Show new distributions from Jan 1, 2019 to the present',
            argv => ['2019-01-01'],
            'x.doc.show_result' => 0,
            test => 0,
        },
        {
            summary => "Show PERLANCAR's new distributions this year",
            argv => ['--include-author', 'PERLANCAR', '--this-year'],
            'x.doc.show_result' => 0,
            test => 0,
        },
        {
            summary => "What are the new releases last month?",
            argv => ['--last-month'],
            'x.doc.show_result' => 0,
            test => 0,
        },
    ],
};
sub list_new_cpan_dists {
    require DateTime;

    my %args = @_;

    my $state = _init(\%args);
    my $dbh = $state->{dbh};

    my $today = DateTime->today;
    my $now = DateTime->now;
    my $end_of_yesterday = $now->clone->add(days => -1)->set(hour => 23, minute => 59, second => 59);
    my $to_time   = $args{to_time} // $now->clone;

    my $from_time;
    if ($args{from_time}) {
        $from_time = $args{from_time};
    } elsif ($args{today}) {
        $from_time = $today;
    } elsif ($args{this_week}) {
        my $dow   = $today->day_of_week;
        $from_time = $today->clone->add(days => -($dow-1));
    } elsif ($args{this_month}) {
        $from_time = $today->clone->set(day => 1);
    } elsif ($args{this_year}) {
        $from_time = $today->set(day => 1, month => 1);
    } elsif ($args{yesterday}) {
        $from_time = $today->add(days => -1);
        $to_time   = $end_of_yesterday;
    } elsif ($args{last_week}) {
        my $dow   = $today->day_of_week;
        my $start_of_last_week = $today->clone->add(days => -($dow-1))->add(days => -7);
        my $end_of_last_week   = $start_of_last_week->clone->add(days => 7)->add(seconds => -1);
        $from_time = $start_of_last_week;
        $to_time   = $end_of_last_week;
    } elsif ($args{last_month}) {
        $from_time = $today->clone->set(day => 1)->add(months => -1);
        $to_time   = $today->clone->set(day => 1)->add(seconds => -1);
    } elsif ($args{last_year}) {
        $from_time = $today->clone->set(day => 1, month => 1)->add(years => -1);
        $to_time   = $today->clone->set(day => 1, month => 1)->add(seconds => -1);
    } else {
        return [400, "Please specify today/yesterday/{this,last}_{week,month,year}/from_time"];
    }

    #if (!$to_time) {
    #    $to_time = $from_time->clone;
    #    $to_time->set_hour(23);
    #    $to_time->set_minute(59);
    #    $to_time->set_second(59);
    #}
    if ($args{-orig_to_time} && $args{-orig_to_time} !~ /T\d\d:\d\d:\d\d/) {
        $to_time->set_hour(23);
        $to_time->set_minute(59);
        $to_time->set_second(59);
    }

    log_trace("Retrieving releases from %s to %s ...",
              $from_time->datetime, $to_time->datetime);

    # list all releases in the time period and collect unique list of
    # distributions
    my $res = _http_tiny->post("$URL_PREFIX/release/_search?size=5000&sort=name", {
        content => _json_encode({
            query => {
                range => {
                    date => {
                        gte => $from_time->datetime,
                        lte => $to_time->datetime,
                    },
                },
            },
            fields => [qw/name author distribution abstract date version version_numified/],
        }),
    });
    return [$res->{status}, "Can't retrieve releases: $res->{reason}"]
        unless $res->{success};

    my $api_res = _json_decode($res->{content});
    my %dists;
    my @res;
    my $num_hits = @{ $api_res->{hits}{hits} };
    my $i = 0;
  HIT:
    for my $hit (@{ $api_res->{hits}{hits} }) {
        $i++;
        my $dist = $hit->{fields}{distribution};
        next if $dists{ $dist }++;
        log_trace("[#%d/%d] Got distribution %s", $i, $num_hits, $dist);
        # find the first release of this distribution
        my $distinfo = _get_dist_release_times($state, $dist);
        unless ($distinfo->{first_time} >= $from_time->epoch &&
                    $distinfo->{first_time} <= $to_time->epoch) {
            log_trace("First release of distribution %s is not in this time period, skipped", $dist);
            next;
        }
        my $row = {
            dist => $dist,
            #release => $hit->{fields}{name},
            author => $hit->{fields}{author},
            first_version => $distinfo->{first_version},
            first_time => $distinfo->{first_time},
            latest_version => $distinfo->{latest_version},
            latest_time => $distinfo->{latest_time},
            abstract => $hit->{fields}{abstract},
            date => $hit->{fields}{date},
        };
        log_trace "row=%s", $row;

      FILTER: {
            if ($args{exclude_dists} && @{ $args{exclude_dists} } &&
                    (grep {$dist eq $_} @{ $args{exclude_dists} })) {
                log_info "Distribution %s is in exclude_dists, skipped", $dist;
                next HIT;
            }
            if ($args{exclude_dist_re} && $dist =~ /$args{exclude_dist_re}/) {
                log_info "Distribution %s matches exclude_dist_re, skipped", $dist;
                next HIT;
            }
            if ($args{include_dists} && @{ $args{include_dists} } &&
                    !(grep {$dist eq $_} @{ $args{include_dists} })) {
                log_info "Distribution %s is not in include_dists, skipped", $dist;
                next HIT;
            }
            if ($args{include_dist_re} && $dist !~ /$args{include_dist_re}/) {
                log_info "Distribution %s does not match include_dist_re, skipped", $dist;
                next HIT;
            }
            if ($args{exclude_authors} && @{ $args{exclude_authors} } &&
                    (grep {$row->{author} eq $_} @{ $args{exclude_authors} })) {
                log_info "Author %s is in exclude_authors, skipped", $row->{author};
                next HIT;
            }
            if ($args{exclude_author_re} && $hit->{fields}{author} =~ /$args{exclude_author_re}/) {
                log_info "Author %s matches exclude_author_re, skipped", $row->{author};
                next HIT;
            }
            if ($args{include_authors} && @{ $args{include_authors} } &&
                    !(grep {$row->{author} eq $_} @{ $args{include_authors} })) {
                log_info "Author %s is not in include_authors, skipped", $row->{author};
                next HIT;
            }
            if ($args{include_author_re} && $hit->{fields}{author} !~ /$args{include_author_re}/) {
                log_info "Author %s does not match include_author_re, skipped", $row->{author};
                next HIT;
            }
        }

        push @res, $row;
    }

    my %resmeta = (
        'table.fields'        => [qw/dist author first_version first_time  latest_version latest_time abstract/],
        'table.field_formats' => [undef,  undef, undef,        'datetime', undef,         'datetime', undef],
        'func.stats' => create_new_cpan_dists_stats(dists => \@res)->[2],
    );

    [200, "OK", \@res, \%resmeta];
}

$SPEC{create_new_cpan_dists_stats} = {
    v => 1.1,
    args => {
        dists => {
            schema => 'array*',
        },
    },
};
sub create_new_cpan_dists_stats {
    my %args = @_;
    my $dists = $args{dists};

    my %authors;
    for my $dist (@$dists) {
        $authors{$dist->{author}} //= {num_dists => 0};
        $authors{$dist->{author}}{num_dists}++;
    }
    my @authors_by_num_dists = map {
        +{author=>$_, num_dists=>$authors{$_}{num_dists}}
    } sort { $authors{$b}{num_dists} <=> $authors{$a}{num_dists} }
    keys %authors;
    my $num_authors = keys %authors;

    my $stats = {
        "Number of new CPAN distributions this period" => scalar(@$dists),
        "Number of authors releasing new CPAN distributions this period" => $num_authors,
        "Authors by number of new CPAN distributions this period" => \@authors_by_num_dists,
    };

    [200, "OK", $stats];
}

$SPEC{list_monthly_new_cpan_dists} = {
    v => 1.1,
    summary => 'List new CPAN distributions in a given month',
    description => <<'_',

Like `list_new_cpan_dists` but you only need to specify month and year instead
of starting and ending time period.

_
    args => {
        %args_filter,
        month => {
            schema => ['int*', min=>1, max=>12],
            req => 1,
            pos => 0,
        },
        year => {
            schema => ['int*', min=>1990, max=>9999],
            req => 1,
            pos => 1,
        },
    },
};
sub list_monthly_new_cpan_dists {
    require DateTime;
    require Time::Local;

    my %args = @_;

    my $mon = delete $args{month};
    my $year = delete $args{year};
    my $from_time = Time::Local::timegm(0, 0, 0, 1, $mon-1, $year);
    $mon++; if ($mon == 13) { $mon = 1; $year++ }
    my $to_time = Time::Local::timegm(0, 0, 0, 1, $mon-1, $year) - 1;
    list_new_cpan_dists(
        %args,
        from_time => DateTime->from_epoch(epoch => $from_time),
        to_time   => DateTime->from_epoch(epoch => $to_time),
        (exclude_dists      => $args{exclude_dists}     ) x !!defined($args{exclude_dists}),
        (exclude_dists_re   => $args{exclude_dists_re}  ) x !!defined($args{exclude_dists_re}),
        (exclude_authors    => $args{exclude_authors}   ) x !!defined($args{exclude_authors}),
        (exclude_authors_re => $args{exclude_authors_re}) x !!defined($args{exclude_authors_re}),
    );
}

$SPEC{list_monthly_new_cpan_dists_html} = {
    v => 1.1,
    summary => 'List new CPAN distributions in a given month (HTML format)',
    description => <<'_',

Like `list_monthly_new_cpan_dists` but produces HTML table instead of data
structure.

_
    args => {
        %args_filter,
        month => {
            schema => ['int*', min=>1, max=>12],
            req => 1,
            pos => 0,
        },
        year => {
            schema => ['int*', min=>1990, max=>9999],
            req => 1,
            pos => 1,
        },
    },
};
sub list_monthly_new_cpan_dists_html {
    require HTML::Entities;

    my %args = @_;

    my $res = list_monthly_new_cpan_dists(%args);

    my @html;

    push @html, "<table>\n";

    my $cols = $res->[3]{'table.fields'};
    push @html, "<tr>\n";
    for my $col (@$cols) {
        next if $col =~ /\A(first|latest)_(time)\z/;
        push @html, "<th>$col</th>\n";
    }
    push @html, "</tr>\n\n";

    {
        no warnings 'uninitialized';
        for my $row (@{ $res->[2] }) {
            push @html, "<tr>\n";
            for my $col (@$cols) {
                next if $col =~ /\A(first|latest)_(time)\z/;
                my $cell = HTML::Entities::encode_entities($row->{$col});
                if ($col eq 'author') {
                    $cell = qq(<a href="https://metacpan.org/author/$cell">$cell</a>);
                } elsif ($col eq 'dist') {
                    $cell = qq(<a href="https://metacpan.org/release/$row->{dist}">$cell</a>);
                }
                push @html, "<td>$cell</td>\n";
            }
            push @html, "</tr>\n";
        }
        push @html, "</table>\n";

        # stats
        my $stats = $res->[3]{'func.stats'};
        push @html, "<h3>Stats</h3>\n";
        push @html, "<p>Number of new CPAN distributions this period: <b>", $stats->{"Number of new CPAN distributions this period"}, "</b></p>\n";
        push @html, "<p>Number of authors releasing new CPAN distributions this period: <b>", $stats->{"Number of authors releasing new CPAN distributions this period"}, "</b></p>\n";
        push @html, "<p>Authors by number of new CPAN distributions this period: </p>\n";
        push @html, "<table>\n";
        push @html, "<tr><th>No</th><th>Author</th><th>Distributions</th></tr>\n";
        my $i = 1;
        for my $rec (@{ $stats->{"Authors by number of new CPAN distributions this period"} }) {
            push @html, qq(<tr><td>$i</td><td><a href="https://metacpan.org/author/$rec->{author}">$rec->{author}</a></td><td>$rec->{num_dists}</td></tr>\n);
            $i++;
        }
        push @html, "</table>\n";
    }

    [200, "OK", join("", @html), {'cmdline.skip_format'=>1}];
}

1;

# ABSTRACT:

=cut
