
package MT::Plugin::SphinxSearch;

use strict;
use warnings;

use base qw( MT::Plugin );

use MT;
use Sphinx;
use File::Spec;
use POSIX;

use MT::Util qw( ts2epoch );

use vars qw( $VERSION $plugin );
$VERSION = '0.99.46mt4';
$plugin = MT::Plugin::SphinxSearch->new ({
        name    => 'SphinxSearch',
        description => 'A search script using the sphinx search engine for MySQL',
        version     => $VERSION,

        author_name => 'Apperceptive, LLC',
        author_link => 'http://www.apperceptive.com/',

        system_config_template  => 'system_config.tmpl',
        settings    => MT::PluginSettings->new ([
            [ 'sphinx_path', { Default => undef, Scope => 'system' }],
            [ 'sphinx_file_path', { Default => undef, Scope => 'system' } ],
            [ 'sphinx_conf_path', { Default => undef, Scope => 'system' }],
            [ 'searchd_host', { Default => 'localhost', Scope => 'system' }],
            [ 'searchd_port', { Default => 3312, Scope => 'system' }],
            [ 'searchd_pid_path', { Default => '/var/log/searchd.pid', Scope => 'system' } ],
            [ 'search_excerpt_words', { Default => 9, Scope => 'system' } ],
            [ 'index_morphology', { Default => 'none', Scope => 'system' } ],
            ]),
                
        init_app    => \&init_apps,        
});
MT->add_plugin ($plugin);

sub instance {
    $plugin;
}

sub init_registry {
    my $plugin = shift;
    my $reg = {
        applications    => {
            cms         => {
                methods => {
                    'gen_sphinx_conf'  => \&gen_sphinx_conf,                    
                }
            }
        },
        tasks   => {
            'sphinx_indexer'    => {
                name    => 'Sphinx Indexer',
                frequency   => 15 * 60,
                code        => sub { $plugin->sphinx_indexer_task (@_) },
            }
        },
        callbacks   => {
            'MT::Template::pre_load'  => \&pre_load_template,
        },
        tags    => {
            function    => {
                'SearchResultsOffset'   => \&search_results_offset_tag,
                'SearchResultsLimit'    => \&search_results_limit_tag,
                'SearchResultsPage'     => \&search_results_page_tag,
        
                'SearchSortMode'        => \&search_sort_mode_tag,
                'SearchMatchMode'       => \&search_match_mode_tag,

                'SearchResultExcerpt'   => \&search_result_excerpt_tag,  
                
                'NextSearchResultsPage' => \&next_search_results_page,
                'PreviousSearchResultsPage' => \&previous_search_results_page,              

                'SearchAllResult'       => \&search_all_result_tag,

                'SearchTotalPages'      => \&search_total_pages_tag,

                'SearchFilterValue'     => \&search_filter_value_tag,

                'SearchParameters'      => \&search_parameters_tag,

                'SearchDateStart'       => \&search_date_start_tag,
                'SearchDateEnd'         => \&search_date_end_tag,
            },
            block   => {
                'IfCurrentSearchResultsPage?'    => \&if_current_search_results_page_conditional_tag,
                'IfNotCurrentSearchResultsPage?' => sub { !if_current_search_results_page_conditional_tag (@_)},
                'IfMultipleSearchResultsPages?'  => \&if_multiple_search_results_pages_conditional_tag,
                'IfSingleSearchResultsPage?'     => sub { !if_multiple_search_results_pages_conditional_tag (@_) },
                
                'SearchResultsPageLoop'  => \&search_results_page_loop_container_tag,
                'SearchNextPage'        => \&search_next_page_tag,
                'SearchPreviousPage'    => \&search_previous_page_tag,
                'SearchCategories'      => \&search_categories_container_tag,
                
                'IfFirstSearchResultsPage?'  => sub { !previous_search_results_page (@_) },
                'IfLastSearchResultsPage?'   => sub { !next_search_results_page (@_) },

                'IfIndexSearched?'               => \&if_index_searched_conditional_tag,

                'IfSearchFiltered?'              => \&if_search_filtered_conditional_tag,
                'IfSearchSortedBy?'              => \&if_search_sorted_by_conditional_tag,

                'IfSearchDateStart?'             => \&if_search_date_start_conditional_tag,
                'IfSearchDateEnd?'               => \&if_search_date_end_conditional_tag,
            },
        }      
    };
    $plugin->registry ($reg);
}

my %indexes;

sub sphinx_indexes {
    return %indexes;
}

sub sphinx_indexer_task {
    my $plugin = shift;
    my $task = shift;
    
    if (!$plugin->check_searchd) {
        if (my $err = $plugin->start_searchd) {
            MT->instance->log ("Error starting searchd: $err");
            die ("Error starting searchd: $err");
        }
    }
    
    if (my $err = $plugin->start_indexer) {
        MT->instance->log ("Error starting sphinx indexer: $err");
        die ("Error starting sphinx indexer: $err");
    }
    
    1;
}

sub init_apps {
    my $plugin = shift;
    my ($app) = @_;

    {
        local $SIG{__WARN__} = sub { };
        *MT::Object::sphinx_init = sub { $plugin->sphinx_init (@_); };
        *MT::Object::sphinx_search = sub { $plugin->sphinx_search (@_); };
    }

    require MT::Entry;
    require MT::Comment;
    MT::Entry->sphinx_init (
        select_values => { status => MT::Entry::RELEASE }, 
        group_columns   => [ 'author_id' ],
        mva => {
            category    => {
                to      => 'MT::Category',
                with    => 'MT::Placement',
                by      => [ 'entry_id', 'category_id' ],
            },
        },
        date_columns => { authored_on => 1 }
    );
    MT::Comment->sphinx_init (select_values => { visible => 1 }, group_columns => [ 'entry_id' ]);
    
    if ($app->isa ('MT::App::Search')) {
        $plugin->init_search_app ($app);
    }
    
}


sub init_search_app {
    my $plugin = shift;
    my ($app) = @_;
        
    if ($app->id eq 'search') {
        local $SIG{__WARN__} = sub { };
        *MT::App::Search::_straight_search = \&straight_sphinx_search;
        *MT::App::Search::_tag_search      = \&straight_sphinx_search;
        *MT::App::Search::Context::_hdlr_result_count = \&result_count_tag;
        my $orig_results = \&MT::App::Search::Context::_hdlr_results;
        *MT::App::Search::Context::_hdlr_results = sub {
            _resort_sphinx_results (@_);
            $orig_results->(@_);
        };        
        
        # we need to short-circuit this as the search string has been stuffed
        # in the case of searchall=1
        my $orig_search_string = \&MT::App::Search::Context::_hdlr_search_string;
        *MT::App::Search::Context::_hdlr_search_string = sub {
            $app->param ('searchall') ? '' : $orig_search_string->(@_);
        };
        
        my $orig_init = \&MT::App::Search::Context::init;
        *MT::App::Search::Context::init = sub {
            my $res = $orig_init->(@_);
            _sphinx_search_context_init (@_);
            return $res;
        }
    }
    elsif ($app->id eq 'new_search') {
        local $SIG{__WARN__} = sub { };
        *MT::App::Search::execute = sub {
            my $results = _get_sphinx_results ($_[0]);
            my @results = (@{$results->{result_objs}});
            return (scalar @results, sub { shift @results });
        }
    }

}

sub _resort_sphinx_results {
    my ($ctx, $args, $cond) = @_;
    
    my $results = $ctx->stash ('results') || return;
    
    $results = [ sort { $a->{entry}->{__sphinx_search_index} <=> $b->{entry}->{__sphinx_search_index} } @$results ];
    $ctx->stash ('results', $results);
}

sub _sphinx_search_context_init {
    my $ctx = shift;
    
    require MT::Request;
    my $r = MT::Request->instance;
    my $stash_name = $r->stash ('sphinx_stash_name');
    my $stash_results = $r->stash ('sphinx_results');
    if ($stash_name && $stash_results) {
        $ctx->stash ($stash_name, $stash_results);
    }
    
    if (my $filter_stash = $r->stash ('sphinx_filters')) {
        while (my ($k, $v) = each %$filter_stash) {
            $ctx->stash ($k, $v);
        }
    }
    
    require MT::App;
    my $app = MT::App->instance;
    if ($app->param ('searchall')) {
        # not cute, but it'll work
        # and with the updated tag handler
        # it shouldn't be exposed
        $ctx->stash ('search_string', 'searchall')
    }
}

sub _get_sphinx {
    my $spx = Sphinx->new;
    $spx->SetServer($plugin->get_config_value ('searchd_host', 'system'), $plugin->get_config_value ('searchd_port', 'system'));

    return $spx;
}

sub _get_sphinx_results {
    my $app = shift;
    my ($res_callback) = @_;
    require MT::Log;
    my $blog_id;
    if ($app->{searchparam}{IncludeBlogs} && scalar (keys %{ $app->{searchparam}{IncludeBlogs} }) == 1) {
        ($blog_id) = keys %{ $app->{searchparam}{IncludeBlogs}};
    }
    
    $app->log({
        message => $app->translate("Search: query for '[_1]'",
              $app->{search_string}),
        level => MT::Log::INFO(),
        class => 'search',
        category => 'straight_search',
        $blog_id ? (blog_id => $blog_id) : ()
    });


    my $spx = _get_sphinx;

    my @indexes = split (/,/, $app->param ('index') || 'entry');
    my @classes;
    foreach my $index (@indexes) {
        my $class = $indexes{$index}->{class};
        eval ("require $class;");
        if ($@) {
            return $app->error ("Error loading $class ($index): " . $@);
        }
        push @classes, $class;
    }
    
    my %classes = map { $_ => 1 } @classes;
    # if MT::Entry is in there, it should be first, just in case
    @classes = ( delete $classes{'MT::Entry'} ? ('MT::Entry') : (), keys %classes);

    my $index = $app->param ('index') || 'entry';
    my $class = $indexes{ $index }->{class};
    my $search_keyword = $app->{search_string};
    
    my $sort_mode = {};
    my $sort_mode_param = $app->param ('sort_mode') || 'descend';
    my $sort_by_param   = $app->param ('sort_by') || $app->param ('index') =~ /\bentry\b/ ? 'authored_on' : 'created_on';
    
    if ($sort_mode_param eq 'descend') {
        $sort_mode = { Descend => $sort_by_param };
    }
    elsif ($sort_mode_param eq 'ascend') {
        $sort_mode = { Ascend => $sort_by_param };
    }
    elsif ($sort_mode_param eq 'relevance') {
        $sort_mode = {};
    }
    elsif ($sort_mode_param eq 'extended') {
        if (my $extended_sort = $app->param ('extended_sort')) {
            $sort_mode = { Extended => $extended_sort };
        }
    }
    elsif ($sort_mode_param eq 'segments') {
        $sort_mode = { Segments => 'authored_on' };
    }
    
    my @blog_ids = keys %{ $app->{ searchparam }{ IncludeBlogs } };
    my $filters = {
        blog_id => \@blog_ids,
    };

    # if it's a tag search,
    # grab all the tag ids we can find for a filter
    # and nix the search keyword
    if ($app->{searchparam}{Type} eq 'tag') {
        require MT::Tag;
        my $tags = $app->{search_string};
        my @tag_names = MT::Tag->split(',', $tags);
        my %tags = map { $_ => 1, MT::Tag->normalize($_) => 1 } @tag_names;
        my @tags = MT::Tag->load({ name => [ keys %tags ] });
        my @tag_ids;
        foreach (@tags) {
            push @tag_ids, $_->id;
            my @more = MT::Tag->load({ n8d_id => $_->n8d_id ? $_->n8d_id : $_->id });
            push @tag_ids, $_->id foreach @more;
        }
        @tag_ids = ( 0 ) unless @tags;
        
        $filters->{tag} = \@tag_ids;
        $search_keyword = undef;
    }

    my $range_filters = {};
    
    if (my $cat_basename = $app->param ('category') || $app->param ('category_basename')) {
        my @all_cats;
        require MT::Category;
        foreach my $cat_base (split (/,/, $cat_basename)) {
            my @cats = MT::Category->load ({ blog_id => \@blog_ids, basename => $cat_base });
            if (@cats) {
                push @all_cats, @cats;
            }
        }
        if (@all_cats) {
            $filters->{category} = [ map { $_->id } @all_cats ];
        }
        
        require MT::Request;
        MT::Request->instance->stash ('sphinx_search_categories', \@all_cats);
    }
    
    if (my $author = $app->param ('author')) {
        require MT::Author;
        my @authors = MT::Author->load ({ name => $author });
        if (@authors) {
            $filters->{author_id} = [ map { $_->id } @authors ];
        }
    }
    
    if ($app->param ('date_start') || $app->param ('date_end')) {
        my $date_start = $app->param ('date_start');
        if ($date_start) {
            $date_start = ts2epoch ($blog_id, $date_start . '0000');
        }
        else {
            $date_start = 0;
        }
        
        my $date_end = $app->param ('date_end');
        if ($date_end) {
            $date_end = ts2epoch ($blog_id, $date_end . '0000');
        }
        else {
            # max timestamp value? maybe 0xFFFFFFFF instead?
            # this is probably large enough
            $date_end = 2147483647;
        }
        
        $range_filters->{created_on} = [ $date_start, $date_end ];
    }
    
    my $filter_stash = {};
    $filter_stash->{"sphinx_filter_$_"} = join (',', @{$range_filters->{$_}}) foreach (keys %$range_filters);
    $filter_stash->{"sphinx_filter_$_"} = join (',', @{$filters->{$_}}) foreach (keys %$filters);
    
    # General catch-all for filters
    my %params = $app->param_hash;
    for my $filter (map { s/^filter_//; $_ } grep { /^filter_/ } keys %params) {
        if (my $lookup = $indexes{$indexes[0]}->{mva}->{$filter}->{lookup}) {
            my $class = $indexes{$indexes[0]}->{mva}->{$filter}->{to};
            eval ("require $class;");
            next if ($@);
            my @v = $class->load ({ $lookup => $app->param ("filter_$filter"), blog_id => \@blog_ids });
            next unless (@v);
            $filters->{$filter} = [ map { $_->id } @v ];
            
            if (my $stash = $indexes{$indexes[0]}->{mva}->{$filter}->{stash}) {
                if (ref ($stash) eq 'ARRAY') {
                    if ($#v) {
                        $filter_stash->{$stash->[1]} = \@v;
                    }
                    else {
                        $filter_stash->{$stash->[0]} = $v[0];
                    }
                }
                else {
                    $filter_stash->{$stash} = \@v;
                }
            }
            $filter_stash->{"sphinx_filter_$filter"} = $app->param ("filter_$filter");
        }
        else {
            $filters->{$filter} = [ $app->param ("filter_$filter") ];            
            $filter_stash->{"sphinx_filter_$filter"} = $app->param ("filter_$filter");
        }
    }
    for my $filter (map { s/^sfilter_//; $_ } grep { /^sfilter_/ } keys %params) {
        require String::CRC32;
        $filters->{$filter . '_crc32'} = [ String::CRC32::crc32 ($app->param ("sfilter_$filter")) ];
        $filter_stash->{"sphinx_filter_$filter"} = $app->param ("sfilter_$filter");
    }
    
    my $offset = $app->param ('offset') || 0;
    my $limit  = $app->param ('limit') || $app->{searchparam}{MaxResults};
    my $max    = MT::Entry->count ({ status => MT::Entry::RELEASE(), blog_id => \@blog_ids });
    
    my $match_mode = $app->param ('match_mode') || 'all';
    
    my $results = $plugin->sphinx_search (\@classes, $search_keyword, 
        Filters         => $filters,
        RangeFilters    => $range_filters,
        Sort            => $sort_mode, 
        Offset          => $offset, 
        Limit           => $limit,
        Match           => $match_mode,
        Max             => $max,
    );
    my $i = 0;
    if (my $stash = $indexes{$indexes[0]}->{stash}) {
        require MT::Request;
        my $r = MT::Request->instance;
        $r->stash ('sphinx_stash_name', $stash);
        $r->stash ('sphinx_results', $results->{result_objs});        
    }
    elsif ($res_callback) {
        foreach my $o (@{$results->{result_objs}}) {
            $res_callback->($o, $i++);
        }        
    }
    
    my $num_pages = ceil ($results->{query_results}->{total} / $limit);
    my $cur_page  = int ($offset / $limit) + 1;
    
    require MT::Request;
    my $r = MT::Request->instance;
    $r->stash ('sphinx_searched_indexes', [ @indexes ]);
    $r->stash ('sphinx_results_total', $results->{query_results}->{total});
    $r->stash ('sphinx_results_total_found', $results->{query_results}->{total_found});
    $r->stash ('sphinx_pages_number', $num_pages);
    $r->stash ('sphinx_pages_current', $cur_page);
    $r->stash ('sphinx_pages_offset', $offset);
    $r->stash ('sphinx_pages_limit', $limit);
    $r->stash ('sphinx_filters', $filter_stash);
    $r->stash ('sphinx_sort_by', $sort_by_param);
    
    $results;
}


sub result_count_tag {
    my ($ctx, $args) = @_;
    require MT::Request;
    my $r = MT::Request->instance;
    return $r->stash ('sphinx_results_total') || 0;
}

sub straight_sphinx_search {
    my $app = shift;

    # Skip out unless either there *is* a search term, or we're explicitly searching all
    return 1 unless ($app->{search_string} =~ /\S/ || $app->param ('searchall'));

    my (%hits);
    my $results = _get_sphinx_results ($app, sub {
        my ($o, $i) = @_;
        my $blog_id = $o->blog_id;
        $o->{__sphinx_search_index} = $i;
        $app->_store_hit_data ($o->blog, $o, $hits{$blog_id}++); 
    });
    1;
}

sub _pid_path {
    my $plugin = shift;
    my $pid_file = $plugin->get_config_value ('searchd_pid_path', 'system');
    my $sphinx_file_path = $plugin->get_config_value ('sphinx_file_path', 'system');
    
    return File::Spec->catfile ($sphinx_file_path, 'searchd.pid') if ($sphinx_file_path);
    return $sphinx_file_path;
}

sub _gen_sphinx_conf_tmpl {
    my $plugin = shift;
    my $tmpl = $plugin->load_tmpl ('sphinx.conf.tmpl') or die $plugin->errstr;
    my %params;
    
    my $app = MT->instance;
    $params{searchd_port} = $plugin->get_config_value ('searchd_port', 'system');
    
    $params{ db_host } = $app->{cfg}->DBHost;
    $params{ db_user } = $app->{cfg}->DBUser;
    my $db_pass        = $app->{cfg}->DBPassword;
    $db_pass =~ s/#/\\#/g;
    $params{ db_pass } = $db_pass;
    $params{  db_db  } = $app->{cfg}->Database;
    $params{ tmp } = $app->{cfg}->TempDir;
    $params{ file_path } = $plugin->get_config_value ('sphinx_file_path', 'system') || $app->{cfg}->TempDir;
    $params{ pid_path } = $plugin->_pid_path;
    $params{ morphology } = $plugin->get_config_value ('index_morphology', 'system') || 'none';
 
    my %info_query;
    my %delta_query;
    my %delta_pre_query;
    my %query;
    my %mva;
    my %counts;
    foreach my $source (keys %indexes) {
        # build any count columns first
        if (my $counts = $indexes{$source}->{count_columns}) {
            for my $count (keys %$counts) {
                my $what_class = $counts->{$count}->{what};
                my $with_column = $counts->{$count}->{with};
                
                eval ("require $what_class;");
                next if ($@);
                
                my $what_ds = $what_class->datasource;
                my $count_query = "SELECT count(*) from mt_$what_ds WHERE ${what_ds}_$with_column = ${source}_" . $indexes{$source}->{id_column};
                $counts{$source}->{$count} = $count_query;
            }            
        }

        $query{$source} = "SELECT " . join(", ", map { 
            $indexes{$source}->{date_columns}->{$_}         ? 'UNIX_TIMESTAMP(' . $source . '_' . $_ . ') as ' . $_ :
            $indexes{$source}->{group_columns}->{$_}        ? "${source}_$_ as " . $indexes{$source}->{group_columns}->{$_} :
            $indexes{$source}->{string_group_columns}->{$_} ? ($source . '_' . $_, "CRC32(${source}_$_) as ${_}_crc32") : 
            $counts{$source}->{$_}                          ? "(" . $counts{$source}->{$_} . ") as $_" :
                                                              $source . '_' . $_
            } ( $indexes{$source}->{ id_column }, @{ $indexes{$source}->{ columns } }, keys %{$counts{$source}} ) ) . 
            " FROM mt_$source";
        if (my $sel_values = $indexes{$source}->{select_values}) {
            $query{$source} .= " WHERE " . join (" AND ", map { "${source}_$_ = \"" . $sel_values->{$_} . "\""} keys %$sel_values);
        }
        $info_query{$source} = "SELECT * from mt_$source where ${source}_" . $indexes{$source}->{ id_column } . ' = $id';
        
        if ($indexes{$source}->{mva}) {
            foreach my $mva (keys %{$indexes{$source}->{mva}}) {
                my $cur_mva = $indexes{$source}->{mva}->{$mva};
                my $mva_query;
                if (ref ($cur_mva)) {
                    my $mva_source = $cur_mva->{with}->datasource;
                    $mva_query = "SELECT " . join (', ', map { "${mva_source}_$_" } @{$cur_mva->{by}}) . " from mt_" . $mva_source;
                    if (my $sel_values = $cur_mva->{select_values}) {
                        $mva_query .= " WHERE " . join (" AND ", map { "${mva_source}_$_ = \"" . $sel_values->{$_} . "\""} keys %$sel_values);
                    }
                    
                }
                else {
                    $mva_query = $cur_mva;
                }
                push @{$mva{$source}}, { mva_query => $mva_query, mva_name => $mva };
            }            
        }
        
        
        if (my $delta = $indexes{$source}->{delta}) {
            $delta_query{$source} = $query{$source};
            $delta_query{$source} .= $indexes{$source}->{select_values} ? " AND " : " WHERE ";
            if (exists $indexes{$source}->{date_columns}->{$delta}) {
                $delta_pre_query{$source} = 'set @cutoff = date_sub(NOW(), INTERVAL 36 HOUR)';
                $delta_query{$source} .= "${source}_${delta} > \@cutoff";
            }
        }
    }
    $params{ source_loop } = [
        map {
                {
                 source => $_,
                 query  => $query{$_},
                 info_query => $info_query{$_},
                 group_loop    => [ map { { group_column => $_ } } ( values %{$indexes{$_}->{group_columns}}, keys %{$counts{$_}} ) ],
                 string_group_loop => [ map { { string_group_column => $_ } } keys %{$indexes{$_}->{string_group_columns}} ],
                 date_loop  => [ map { { date_column => $_ } } keys %{$indexes{$_}->{date_columns}} ],
                 delta_pre_query => $delta_pre_query{$_},
                 delta_query  => $delta_query{$_},
                 mva_loop   => $mva{$_} || [],
                } 
        }
        keys %indexes
    ];
    $tmpl->param (\%params);
    $tmpl;
}


sub gen_sphinx_conf {
    my $app = shift;
    my $tmpl = $plugin->_gen_sphinx_conf_tmpl;
    
    my $str = $app->build_page ($tmpl);
    die $app->errstr if (!$str);
    $app->{no_print_body} = 1;
    $app->set_header("Content-Disposition" => "attachment; filename=sphinx.conf");
    $app->send_http_header ('text/plain');
    $app->print ($str);
}

sub start_indexer {
    my $plugin = shift;
    my $sphinx_path = $plugin->get_config_value ('sphinx_path', 'system') or return "Sphinx path is not set";

    my $sphinx_conf = $plugin->get_config_value ('sphinx_conf_path', 'system') or return "Sphinx conf path is not set";
    my $indexer_binary = File::Spec->catfile ($sphinx_path, 'indexer');
    my $str = `$indexer_binary --quiet --config $sphinx_conf --all --rotate`;
    
    my $return_code = $? / 256;
    return $str if ($return_code);
    return undef;
}

sub check_searchd {
    my $plugin = shift;
    my $pid_path = $plugin->_pid_path;
    
    open my $pid_file, "<", $pid_path or return undef;
    local $/ = undef;
    my $pid = <$pid_file>;
    close $pid_file;
    
    # returns number of process that exist and can be signaled
    # sends a 0 signal, which is meaningless as far as I can tell
    return kill 0, $pid;
}


sub start_searchd {
    my $plugin = shift;
    
    my $bin_path = $plugin->get_config_value ('sphinx_path', 'system') or return "Sphinx path is not set";
    my $conf_path = $plugin->get_config_value ('sphinx_conf_path', 'system') or return "Sphinx conf path is not set";
    my $file_path = $plugin->get_config_value ('sphinx_file_path', 'system') or return "Sphinx file path is not set";
    
    # Check for lock files and nix them if they exist
    # it's assumed that searchd is *not* running when this function is called
    foreach my $source (keys %indexes) {
        my $lock_path = File::Spec->catfile ($file_path, $source . '_index.spl');
        if (-f $lock_path) {
            unlink $lock_path;
        }
    }
    
    my $searchd_path = File::Spec->catfile ($bin_path, 'searchd');
    
    my $out = `$searchd_path --config $conf_path`;
    my $return_code = $? / 256;
    
    return $out if ($return_code);
    return undef;
}

sub sphinx_init {
    my $plugin = shift;
    my ($class, %params) = @_;
    
    my $datasource = $class->datasource;

    return if (exists $indexes{ $datasource });
    
    my $props = $class->properties;

    my $primary_key = $props->{primary_key};
    my $defs = $class->column_defs;
    my $columns = [ grep { $_ ne $primary_key } keys %$defs ];
    my $columns_hash = { map { $_ => 1 } @$columns };
    if ($params{include_columns}) {
        my $includes = { map { $_ => 1} @{$params{include_columns}} };
        $columns = [ grep {exists $includes->{$_}} @$columns ];
    }
    elsif ($params{exclude_columns}) {
        my $excludes = { map { $_ => 1 } @{$params{exclude_columns}} };
        $columns = [ grep { !exists $excludes->{$_} } @$columns ];
    }
    my $id_column = $params{id_column} || $primary_key;
    $indexes{ $datasource } = {
        id_column   => $id_column,
        columns     => $columns,
    };
    $indexes{ $datasource }->{class} = $class;
    $indexes{ $datasource }->{delta} = $params{delta};
    $indexes{ $datasource }->{stash} = $params{stash};
    $indexes{ $datasource }->{count_columns} = $params{count_columns};
    
    if (exists $defs->{ blog_id }) {
        $indexes{ $datasource }->{ group_columns }->{ blog_id } = 'blog_id';
    }
    
    if (exists $props->{indexes}) {
        # push all the indexes that are actual columns
        push @{$params{group_columns}}, grep { $columns_hash->{$_} } keys %{$props->{indexes}};
    }
    
    if (exists $params{group_columns}) {
        for my $column (@{$params{group_columns}}) {
            next if ($column eq $id_column); # skip if this is the id column, don't need to group on it after all
            my $name;
            if ('HASH' eq ref ($column)) {
                ($column, $name) = each (%$column);
            }
            else {
                $name = $column;
            }
            my $col_type = $defs->{$column}->{type};
            if ($col_type =~ /^(datetime|timestamp)/) {
                # snuck in from indexes, we should push it into the date columns instead
                $params{date_columns}->{$column} = 1;
            }
            else {                
                $indexes{ $datasource }->{ $defs->{$column}->{type} =~ /^(string|text)$/ ? 'string_group_columns' : 'group_columns' }->{$column} = $name;
            }
        }
    }
    
    if ($props->{audit}) {
        $indexes{$datasource}->{date_columns}->{'created_on'}++;
        $indexes{$datasource}->{date_columns}->{'modified_on'}++;
        
        $indexes{$datasource}->{delta} = 'modified_on' if (!$indexes{$datasource}->{delta});
    }
    
    if (exists $params{date_columns}) {
        $indexes{$datasource}->{date_columns}->{$_}++ foreach (ref ($params{date_columns}) eq 'HASH' ? keys %{$params{date_columns}} : @{$params{date_columns}});
    }
    
    if (exists $params{select_values}) {
        $indexes{ $datasource }->{select_values} = $params{select_values};
    }    
    
    if (exists $params{mva}) {
        $indexes{ $datasource }->{mva} = $params{mva};
    }
    
    if ($class->isa ('MT::Taggable')) {
        require MT::Tag;
        require MT::ObjectTag;
        # if it's taggable, setup the MVA bits
        $indexes{ $datasource }->{ mva }->{ tag } = {
            to      => 'MT::Tag',
            with    => 'MT::ObjectTag',
            by      => [ 'object_id', 'tag_id' ],
            select_values   => { object_datasource => $datasource },
        };
    }
    
    $indexes{ $datasource }->{id_to_obj} = $params{id_to_obj} || sub { $class->load ($_[0]) };
}

sub _process_extended_sort {
    my $plugin = shift;
    my ($class, $sort_string) = @_;
    
    my $datasource = $class->datasource;
    
    $sort_string =~ s/(?<!@)\b(\w+)\b(?!(?:,|$))/${datasource}_$1/gi;    
    $sort_string;
}


sub sphinx_search {
    my $plugin = shift;
    my ($classes, $search, %params) = @_;

    my @classes;
    if (ref $classes) {
        @classes = @$classes;
    }
    else {
        @classes = ($classes);
    }

    # I'm sure there's a better way to do this bit
    # but it's working for now
    my $class;
    my $datasource;
    for my $c (reverse @classes) {
        $class = $c;
        $datasource = $class->datasource;
        return () if (!exists $indexes{ $datasource });
    }
        
    my $spx = _get_sphinx();
    
    if (exists $params{Filters}) {
        foreach my $filter (keys %{ $params{Filters} }) {
            $spx->SetFilter($filter, $params{Filters}{$filter});
        }
    }
    
    if (exists $params{SFilters}) {
        require String::CRC32;
        foreach my $filter (keys %{ $params{SFilters} }) {
            $spx->SetFilter ($filter . '_crc32', [ map { String::CRC32::crc32 ($_) } @{$params{SFilters}{$filter}} ] );
        }
    }
    
    if (exists $params{RangeFilters}) {
        foreach my $filter (keys %{ $params{RangeFilters} }) {
            $spx->SetFilterRange ($filter, @{$params{RangeFilters}->{$filter}});
        }
    }
    
    if (exists $params{Sort}) {
        exists $params{Sort}->{Ascend}      ?   $spx->SetSortMode (Sphinx::SPH_SORT_ATTR_ASC, $params{Sort}->{Ascend}) :
        exists $params{Sort}->{Descend}     ?   $spx->SetSortMode (Sphinx::SPH_SORT_ATTR_DESC, $params{Sort}->{Descend}) :
        exists $params{Sort}->{Segments}    ?   $spx->SetSortMode (Sphinx::SPH_SORT_TIME_SEGMENTS, $params{Sort}->{Segments}) :
        exists $params{Sort}->{Extended}    ?   $spx->SetSortMode (Sphinx::SPH_SORT_EXTENDED, $plugin->_process_extended_sort ($class, $params{Sort}->{Extended})) :
                                                $spx->SetSortMode (Sphinx::SPH_SORT_RELEVANCE);
    }
    else {
        # Default to explicitly setting the sort mode to relevance
        $spx->SetSortMode (Sphinx::SPH_SORT_RELEVANCE);
    }
    
    if (exists $params{Match}) {
        my $match = $params{Match};
        $match eq 'extended'? $spx->SetMatchMode (Sphinx::SPH_MATCH_EXTENDED):
        $match eq 'boolean' ? $spx->SetMatchMode (Sphinx::SPH_MATCH_BOOLEAN) :
        $match eq 'phrase'  ? $spx->SetMatchMode (Sphinx::SPH_MATCH_PHRASE)  :
        $match eq 'any'     ? $spx->SetMatchMode (Sphinx::SPH_MATCH_ANY)     :
                              $spx->SetMatchMode (Sphinx::SPH_MATCH_ALL);
    }
    else {
        $spx->SetMatchMode (Sphinx::SPH_MATCH_ALL);
    }
    
    my $offset = 0;
    my $limit  = 200;
    my $max    = 0;
    if (exists $params{Offset}) {
        $offset = $params{Offset};
    }
    
    if (exists $params{Limit}) {
        $limit = $params{Limit};
    }
    
    if (exists $params{Max}) {
        $max = $params{Max};
    }
    
    $spx->SetLimits ($offset, $limit, $max);
    
    my $results = $spx->Query ($search, join ( ' ', map { my $ds = $_->datasource; $ds . '_index' . ( $indexes{$ds}->{delta} ? " ${ds}_delta_index" : '' ) } @classes ) );
    if (!$results) {
        MT->instance->log ({
            message => "Error querying searchd daemon: " . $spx->GetLastError,
            level   => MT::Log::ERROR(),
            class   => 'search',
            category    => 'straight_search',
        });
        return ();
    }

    my @result_objs = ();
    my $meth = $indexes{ $datasource }->{id_to_obj} or die "No id_to_obj method for $datasource";
    foreach my $match (@{$results->{ matches }}) {
        my $id = $match->{ doc };
        my $o = $meth->($id) or next;
        push @result_objs, $o;
    }
    
    return @result_objs if wantarray;
    return {
        result_objs     => [ @result_objs ],
        query_results   => $results,
    };
    
}

sub search_results_page_loop_container_tag {
    my ($ctx, $args, $cond) = @_;
    
    require MT::Request;
    my $r = MT::Request->instance;
    my $number_pages = $r->stash ('sphinx_pages_number');
    my $current_page = $r->stash ('sphinx_pages_current');
    my $limit        = $r->stash ('sphinx_pages_limit');
    my $builder = $ctx->stash ('builder');
    my $tokens  = $ctx->stash ('tokens');
    
    my $res = '';
    my $glue = $args->{glue} || '';
    my $lastn = $args->{lastn};
    $lastn = 0 if (2 * $lastn + 1 > $number_pages);
    my $low_end = !$lastn ? 1 : 
                  $current_page - $lastn > 0 ? $current_page - $lastn : 
                  1;
    my $high_end = !$lastn ? $number_pages : 
                   $current_page + $lastn > $number_pages ? $number_pages : 
                   $current_page + $lastn;
    my @pages = ($low_end .. $high_end);
    while ($lastn && scalar @pages < 2 * $lastn + 1) {
        unshift @pages, $pages[0] - 1 if ($pages[0] > 1);    
        push @pages, $pages[$#pages] + 1 if ($pages[$#pages] < $number_pages);
    }
    
    local $ctx->{__stash}{sphinx_page_loop_first} = $pages[0];
    local $ctx->{__stash}{sphinx_page_loop_last}  = $pages[$#pages];
    for my $page (@pages) {
        local $ctx->{__stash}{sphinx_page_number} = $page;
        # offset is 0 for page 1, limit for page 2, limit * 2 for page 3, ...
        local $ctx->{__stash}{sphinx_pages_offset} = ($page - 1) * $limit;
        defined (my $out = $builder->build ($ctx, $tokens, {
            %$cond,
            IfCurrentSearchResultsPage => ($page == $current_page),
        })) or return $ctx->error ($builder->errstr);
        $res .= $glue if $res ne '';
        $res .= $out;
    }
    $res;
}

sub search_results_limit_tag {
    my ($ctx, $args) = @_;
    
    require MT::Request;
    my $r = MT::Request->instance;
    
    return $r->stash ('sphinx_pages_limit') || 0;
}

sub search_results_offset_tag {
    my ($ctx, $args) = @_;
    
    my $offset = $ctx->stash ('sphinx_pages_offset');
    return $offset if defined $offset;
    
    require MT::Request;
    my $r = MT::Request->instance;
    return $r->stash ('sphinx_pages_offset') || 0;
}

sub search_results_page_tag {
    my ($ctx, $args) = @_;
    my $page_number = $ctx->stash ('sphinx_page_number');
    return $page_number if $page_number;
    
    require MT::Request;
    my $r = MT::Request->instance;
    return $r->stash ('sphinx_pages_current') || 0;
}

sub search_sort_mode_tag {
    my ($ctx, $args) = @_;
    
    require MT::App;
    my $app = MT::App->instance;
    my $mode = $app->param ('sort_mode') || 'descend';
    return $mode;
}

sub search_match_mode_tag {
    my ($ctx, $args) = @_;
        
    require MT::App;
    my $app = MT::App->instance;
    my $mode = $app->param ('match_mode') || 'all';
    return $mode;
}

sub if_current_search_results_page_conditional_tag {
    $_[2]->{ifcurrentsearchresultspage};
}

sub if_multiple_search_results_pages_conditional_tag {
    require MT::Request;
    my $r = MT::Request->instance;
    my $number_pages = $r->stash ('sphinx_pages_number');
    return $number_pages > 1;
}

sub search_result_excerpt_tag {
    my ($ctx, $args) = @_;
    
    my $entry = $ctx->stash ('entry') or return $ctx->_no_entry_error ('MTSearchResultExcerpt');
    
    require MT::App;
    my $app = MT::App->instance;
    my $search_string = $app->{search_string};
    my $words = $plugin->get_config_value ('search_excerpt_words', 'system');
    
    require MT::Util;
    TEXT_FIELD:
    for my $text ($entry->text, $entry->text_more) {
        $text = MT::Util::remove_html ($text);
        if ($text && $text =~ /(((([\w']+)\b\W*){0,$words})$search_string\b\W*((([\w']+)\b\W*){0,$words}))/ims) {
            my ($excerpt, $pre, $post) = ($1, $2, $5);
            $excerpt =~ s{($search_string)}{<b>$1</b>}ig;
            $entry->excerpt ($excerpt);
            last TEXT_FIELD;
        }        
        
    }
        
    my ($handler) = $ctx->handler_for ('EntryExcerpt');
    return $handler->($ctx, $args);
}

sub next_search_results_page {
    my ($ctx, $args, $cond) = @_;
    require MT::Request;
    my $r = MT::Request->instance;
    my $number_pages = $r->stash ('sphinx_pages_number');
    my $current_page = $r->stash ('sphinx_pages_current');
    
    $current_page == $number_pages ? '' : $current_page + 1;
}

sub previous_search_results_page {
    my ($ctx, $args, $cond) = @_;
    require MT::Request;
    my $r = MT::Request->instance;
    my $number_pages = $r->stash ('sphinx_pages_number');
    my $current_page = $r->stash ('sphinx_pages_current');
    
    $current_page == 1 ? '' : $current_page - 1;
}

sub search_all_result_tag {
    require MT::App;
    MT::App->instance->param ('searchall') ? 1 : 0;
}

sub search_total_pages_tag {
    require MT::Request;
    MT::Request->instance->stash ('sphinx_pages_number');
}

sub search_next_page_tag {
    my ($ctx, $args, $cond) = @_;
    require MT::Request;
    my $r = MT::Request->instance;
    my $current_page = $r->stash ('sphinx_pages_current');
    my $number_pages = $r->stash ('sphinx_pages_number');
    
    return '' if ($current_page >= $number_pages);

    my $page = $current_page + 1;
    
    my $limit   = $r->stash ('sphinx_pages_limit');
    my $builder = $ctx->stash ('builder');
    my $tokens  = $ctx->stash ('tokens');
    
    local $ctx->{__stash}{sphinx_page_number} = $page;
    # offset is 0 for page 1, limit for page 2, limit * 2 for page 3, ...
    local $ctx->{__stash}{sphinx_pages_offset} = ($page - 1) * $limit;
    defined (my $out = $builder->build ($ctx, $tokens, {
        %$cond,
        IfCurrentSearchResultsPage => ($page == $current_page),
    })) or return $ctx->error ($builder->errstr);
    $out;
}

sub search_previous_page_tag {
    my ($ctx, $args, $cond) = @_;
    require MT::Request;
    my $r = MT::Request->instance;
    my $current_page = $r->stash ('sphinx_pages_current');
    
    return '' if ($current_page <= 1);

    my $page = $current_page - 1;

    my $limit   = $r->stash ('sphinx_pages_limit');
    my $builder = $ctx->stash ('builder');
    my $tokens  = $ctx->stash ('tokens');

    local $ctx->{__stash}{sphinx_page_number} = $page;
    # offset is 0 for page 1, limit for page 2, limit * 2 for page 3, ...
    local $ctx->{__stash}{sphinx_pages_offset} = ($page - 1) * $limit;
    defined (my $out = $builder->build ($ctx, $tokens, {
        %$cond,
        IfCurrentSearchResultsPage => ($page == $current_page),
    })) or return $ctx->error ($builder->errstr);
    $out;
}

sub if_first_search_results_page_conditional_tag {
    my ($ctx, $args) = @_;
    if (my $first = $ctx->stash ('sphinx_page_loop_first')) {
        return $ctx->stash ('sphinx_page_number') == $first;
    }
    else {
        require MT::Request;
        my $current_page = MT::Request->instance->stash ('sphinx_pages_current');
        return $current_page == 1;
    }
}

sub if_last_search_results_page_conditional_tag {
    my ($ctx, $args) = @_;
    if (my $last = $ctx->stash ('sphinx_page_loop_last')) {
        return $ctx->stash ('sphinx_page_number') == $last;
    }
    else {
        require MT::Request;
        my $r = MT::Request->instance;
        my $current_page = $r->stash ('sphinx_pages_current');
        my $number_pages = $r->stash ('sphinx_pages_number');
        return $current_page == $number_pages;
    }
}

sub search_categories_container_tag {
    my($ctx, $args, $cond) = @_;

    require MT::Request;
    my $cats = MT::Request->instance->stash ('sphinx_search_categories');
    return '' if (!$cats);
    require MT::Placement;

    my @cats = sort { $a->label cmp $b->label } @$cats;
    my $res = '';
    my $builder = $ctx->stash('builder');
    my $tokens = $ctx->stash('tokens');
    my $glue = exists $args->{glue} ? $args->{glue} : '';
    ## In order for this handler to double as the handler for
    ## <MTArchiveList archive_type="Category">, it needs to support
    ## the <$MTArchiveLink$> and <$MTArchiveTitle$> tags
    local $ctx->{inside_mt_categories} = 1;
    for my $cat (@cats) {
        local $ctx->{__stash}{category} = $cat;

        # Don't think we need all these bits right now
        # local $ctx->{__stash}{entries};
        # local $ctx->{__stash}{category_count};
        # local $ctx->{__stash}{blog_id} = $cat->blog_id;
        # local $ctx->{__stash}{blog} = MT::Blog->load($cat->blog_id, { cached_ok => 1 });
        # my @args = (
        #     { blog_id => $cat->blog_id,
        #       status => MT::Entry::RELEASE() },
        #     { 'join' => [ 'MT::Placement', 'entry_id',
        #                   { category_id => $cat->id } ],
        #       'sort' => 'created_on',
        #       direction => 'descend', });
        # $ctx->{__stash}{category_count} = MT::Entry->count(@args);
        # next unless $ctx->{__stash}{category_count} || $args->{show_empty};
        
        defined(my $out = $builder->build($ctx, $tokens, $cond))
            or return $ctx->error( $builder->errstr );
        $res .= $glue if $res ne '';
        $res .= $out;
    }
    $res;
}

sub if_index_searched_conditional_tag {
    my ($ctx, $args) = @_;
    my $index = $args->{name} || $args->{index};
    return 0 if (!$index);
    require MT::Request;
    my $indexes = MT::Request->instance->stash ('sphinx_searched_indexes');
    return $indexes && scalar grep { $_ eq $index } @$indexes;
}

sub pre_load_template {
    my ($cb, $params) = @_;
    
    # skip out of here if this isn't a search app
    # we don't want to screw anything up
    require MT::App;
    my $app = MT::App->instance;
    return unless ($app && $app->isa ('MT::App::Search'));
    
    
    return unless (my $tmpl_id = $app->param ('tmpl_id'));
    if ('HASH' eq ref ($params->[1]) && scalar keys %{$params->[1]} == 2 && $params->[1]->{blog_id} && $params->[1]->{type} eq 'search_template') {
        $params->[1] = $tmpl_id;
    }
}

sub if_search_filtered_conditional_tag {
    my ($ctx, $args) = @_;
    my $filter_name = $args->{name} || $args->{filter};
    if ($filter_name) {
        return $ctx->stash ("sphinx_filter_$filter_name") ? 1 : 0;        
    }
    else {
        require MT::Request;
        return MT::Request->instance->stash ('sphinx_filters');
    }
}

sub search_filter_value_tag {
    my ($ctx, $args) = @_;
    my $filter_name = $args->{name} || $args->{filter} or return $ctx->error ('filter or name required');
    my $filter_value = $ctx->stash ("sphinx_filter_$filter_name");
    return $filter_value ? $filter_value : '';
}

sub if_search_sorted_by_conditional_tag {
    my ($ctx, $args) = @_;
    my $sort_arg = $args->{sort} or return 0;
    require MT::Request;
    my $sort_by = MT::Request->instance->stash ('sphinx_sort_by');
    return $sort_by eq $sort_arg;
}

sub search_parameters_tag {
    my ($ctx, $args) = @_;
    
    my %skips = map { $_ => 1 } split (/,/, $args->{skip});
    require MT::App;
    my $app = MT::App->instance;
    my %params = $app->param_hash;
    require MT::Util;
    return join ('&', map { $_ . '=' . MT::Util::encode_url ($params{$_}) } grep { !exists $skips{$_} }keys %params);
}

sub if_search_date_start_conditional_tag {
    require MT::App;
    my $app = MT::App->instance;
    return defined $app->param ('date_start');
}

sub if_search_date_end_conditional_tag {
    require MT::App;
    my $app = MT::App->instance;
    return defined $app->param ('date_end');
}

sub search_date_start_tag {
    require MT::App;
    my $app = MT::App->instance;
    local $_[0]->{current_timestamp} = $app->param ('date_start') . '0000';
        
    require MT::Template::ContextHandlers;
    MT::Template::Context::_hdlr_date (@_);
}

sub search_date_end_tag {
    require MT::App;
    my $app = MT::App->instance;
    local $_[0]->{current_timestamp} = $app->param ('date_end') . '0000';
    
    require MT::Template::ContextHandlers;
    MT::Template::Context::_hdlr_date (@_);
}


1;