#!/usr/bin/perl

use strict;
use Pithub::Issues;
use Data::Dumper;
use Storable;
use Getopt::Long;
use YAML::Tiny;
use File::Basename;

=pod

=head1 Issue transfer script

Simple script for moving issues from one repo to another

=cut



$|=1;

# Read options and config
my $opts = {};
GetOptions($opts,
           "config|c=s",
           "debug|d",
           "labels|label|l",
           "repo|r=s",
           "oneshot",
           "target|t=s",
           "user=s",
           "token=s",
           "dry-run|n",
           "clean",
           "links",
           "state=s",
           "pause=s",
           "help|h"
          );
if ($opts->{help}) {
    &usage;
    exit 0;
}

# Configuration (if existing)
my $config_file = $opts->{config} || dirname(__FILE__) . "/config.yml";
if (! -f -f $config_file) {
    &usage(">>>> No configuration file $config_file found");
}


my $config= YAML::Tiny->read($config_file)->[0];

if ($opts->{repo}) {
    # Target repository
    my $target = $opts->{target} || $config->{target};
    &migrate_repo($opts, $config);
} elsif ($opts->{labels}) {
    &create_labels($opts, $config);
} elsif ($opts->{links}) {
    &update_links($opts, $config);
} else {
    &usage("Either --labels or --repo must be provided");
    exit 1;
}

sub usage {
    my $extra = shift;

    print <<EOT;
Migrate issue from one GitHub repo to another

Usage: $0 [...options...] (--labels|--repo <repo>)

Mandatory arguments (alternatively):
   --repo <repo>     : Migrate repo <repo> to target repo
   --labels          : Create labels in target repo
   --links           : Update links *after* a migration

Options:
   --config <config> : Configuration file holding mappings and auth information. Default: "<script dir>/config.yml"
   --debug           : Output debug information
   --oneshot         : Migrate only the first issue (for testing)
   --target <target> : Target repo in the format "syndesisio/syndesis"
   --user <user>     : User to use for the migration
   --token <token>   : GitHub auth token
   --dry             : Don't write, only test
   --clean           : Use a new fresh cache and remove the cache from the previous run
   --state <file>    : State file to use
   --pause <wait s>  : Pause for that main seconds after each write (default: 5s, use this to comply to 
                       https://developer.github.com/v3/guides/best-practices-for-integrators/#dealing-with-abuse-rate-limits)
   --help            : this help message

EOT
    print ">>> $extra\n\n" if $extra;    
}


# ===============================================================================================

sub update_links {
    my $opts = shift;
    my $config = shift;

    my $repo = $opts->{repo};

    my $state = $opts->{clean} ? {} : load_state($opts, $config);

    my $target_issues = Pithub::Issues->new(&parse_auth($opts, $config));
    my $list_result = $target_issues->list(&get_target_repo($opts,$config),
                                           params => { state => 'open', direction => 'asc', sort => 'updated' },
                                           auto_pagination => 1
                                          );
    my $count = 0;
    print "Updating links for '$repo':\n";
    my $repo_map = extract_repo_map($config);
    while (my $issue = $list_result->next) {
        # Ignore pull requests
        next if $issue->{pull_request};
        next unless $issue->{body} =~ m/\s(\w+?\/\w+?)?#(\d+)(\s|\.|$)/;
        my $issue_id = $issue->{number};
        print Dumper($issue); exit 0;
        print "$issue_id: ";
        my $body = $issue->{body};
        my $processed = $state->{_links}->{$issue_id}->{body} || {};

        print $body;
        my $replacer = sub {
            my $repo_name = shift;
            my $number = shift;

            my $repo;
            if ($repo_name) {
                $repo = $repo_map->{$repo_name};
                return $repo_name . "#" . $number unless $repo;
            } else {
                $repo = &extract_module_repo_from_labels($issue);
            }
            my $mapped = $state->{$repo}->{$number};
            if ($mapped) {
                return "#" . $mapped->{new_id};
            } else {
                return $repo_name . "#" . $number;
            }
        };
        $body =~ s/(\s)([\w\-]+?\/[\w\-]+?)?#(\d+)(\s|\.|$)/$1 . &$replacer($2,$3) . $4/ge;
        print $body;
        $state->{_links}->{$issue_id}->{body} = $processed;
        #save_state($opts, $config, $state);
        exit 0;
    }
}

sub extract_repo_map {
    my $config = shift;
    my $ret = {};
    for my $repo (keys %{$config->{repos}}) {
        $ret->{$config->{repos}->{$repo}->{name}} = $repo;
    }
    return $ret;
}

sub extract_module_repo_from_labels {
    my $issue = shift;
    for my $label (@{$issue->{labels}}) {
        if ($label->{name} =~ m|module/(.*)$|) {
            return $1;
        }
    }
    return undef;
}


sub migrate_repo {
    my $opts = shift;
    my $config = shift;

    my $repo = $opts->{repo} || die "No repo given";

    # Cache for already processed issues
    my $state = $opts->{clean} ? {} : load_state($opts, $config);

    # Milestone mapping
    my $milestone_map = &extract_milestones($opts, $config);

    print "Migrating $repo:\n";
    
    # Fetch all source issues
    my $source_issues = Pithub::Issues->new(&parse_auth($opts, $config));
    my $source = $config->{repos}->{$repo} || die "Unknown repo '$repo'";
    my $list_result = $source_issues->list(
                                           &parse_repo($source->{name}),
                                           params => { state => 'open', direction => 'asc', sort => 'updated' },
                                           auto_pagination => 1,
                                          );
    # Handle for the target issues
    my $target_issues = Pithub::Issues->new(&parse_auth($opts, $config));

    
    my $count = 0;
    while (my $issue = $list_result->next) {
        # Ignore pull requests
        next if $issue->{pull_request};

        
        # Temporary checks to find issues of a certain kind
        # next unless $issue->{assignee};
        # next if !$issue->{comments} || ! @{$issue->{labels}};
        # next if !$issue->{milestone};

        my $issue_id = $issue->{number};        
        print $issue_id,": ";

        # Get persisten cache for this issue
        my $cache = $state->{$repo}->{$issue_id};

        my $new_issue_id;
        if (!$cache) {
            #printf "%3s %40.40s
            #%s\n",$issue->{number},$issue->{title},$issue->{comments};
            if (!$opts->{"dry-run"}) {
                my $new_issue_result = $target_issues->create(
                                                              &get_target_repo($opts,$config),
                                                              data => {
                                                                       assignee => ($issue->{assignee} ? $issue->{assignee}->{login} : undef),
                                                                       body => prepare_body($issue),
                                                                       labels => map_labels($config, $repo, $issue->{labels}),
                                                                       milestone => map_milestone($issue->{milestone},$milestone_map),
                                                                       title => $issue->{title}
                                                                      }
                                                             );
                die_on_error($new_issue_result, $opts);
                $new_issue_id = $new_issue_result->first->{number}; 
                $count++;                

                $cache = {};
                $cache->{new_id} = $new_issue_id;
                $cache->{comments} = {};
                $state->{$repo}->{$issue_id} = $cache;
                save_state($opts, $config, $state);
                sleep ($opts->{pause} || 5);
            } else {
                map_labels($config, $repo, $issue->{labels});
                map_milestone($issue->{milestone},$milestone_map);
                print "[N] ";
            }
        } else {
            print "[C] ";
            $new_issue_id = $cache->{new_id};
        }
        
        if ($issue->{comments} > 0) {
            my $comments_result = $source_issues->comments->list(
                                                                 &parse_repo($source->{name}),
                                                                 issue_id => $issue_id,
                                                                 auto_pagination => 1
                                                                );
            
            while (my $comment = $comments_result->next) {
                my $comment_id = $comment->{id};
                if ($cache->{comments}->{$comment_id}) {
                    print ".";
                    next;
                }
                if (!$opts->{"dry-run"}) {
                    my $new_comment_result = $target_issues->comments->create(&get_target_repo($opts,$config),
                                                                              issue_id => $new_issue_id,
                                                                              data => { body => map_comment($comment) }
                                                                             );                
                    die_on_error($new_comment_result, $opts);
                    print "+";
                    sleep ($opts->{pause} || 5);
                    $count++;
                    # print Dumper($comment);
                    $cache->{comments}->{$comment_id} = $new_comment_result->content->{id};
                    save_state($opts, $config,$state);
                } else {
                    print "-";
                }
            }
        }
        print " : ",$new_issue_id,"\n";
        save_state($opts, $config, $state);

        if ($count > 0 && ($count % 25 == 0)) {
            print "Sleeping for 60s to avoid rate limiting ...\n";
            sleep 60;
        }
        exit 0 if $opts->{oneshot};
    }
    print "Done.\n";
}

sub create_labels {
    my $opts = shift;
    my $config = shift;

    my $target_labels = Pithub::Issues->new(&parse_auth($opts, $config))->labels;
    my $labels = $config->{labels} || die "No labels: defined in configuration";
    for my $label (sort keys %$labels) {
        my $color = $labels->{$label};
        printf "%-20s [%s]: ",$label,$color;
        my $result = $target_labels->create(
                                            &get_target_repo($opts, $config),
                                            data => {
                                                     name => $label,
                                                     color => $color
                                                    }
                                           );
        if (!$result->success) {
            my $error = $result->content;
            if ($error->{errors}->[0]->{code} eq 'already_exists') {
                print "update\n";
                my $r = $target_labels->update(
                                               &get_target_repo($opts, $config),
                                               label => $label,
                                               data => {
                                                        name => $label,
                                                        color => $color
                                                       }
                                              );
                die Dumper($r->content) unless $r->success;
            } else {
                die Dumper($error);
            }
        } else {
            print "new\n";
        }
    }
}

# ==============================================================================================

sub die_on_error {
    my $result = shift;
    my $opts = shift || {};
    if (!$result->success) {
        print Dumper($result) if $opts->{debug};
        my $content = $result->content;
        print "ERROR: ",$content->{message},"\n";
        print Dumper($content);
        my $response = $result->response;
        print
          "Rate limit: ",$response->header("x-ratelimit-limit"),
          ", remaining: ",$response->header("x-ratelimit-remaining"),
          ", next reset: ",scalar(localtime($response->header("x-ratelimit-reset"))),"\n";
        die "Exit ... Please retry later\n";
    }

};

sub prepare_body {
    my $issue = shift;
    my $body = $issue->{body};
    my $user = "@" . $issue->{user}->{login};
    my $user_avatar = $issue->{user}->{avatar_url};
    my $labels = create_label_html($issue->{labels});
    my $created = $issue->{created_at};
    $created =~ s/.*(\d{4}-\d{2}-\d{2}).*/$1/;
    
    my $header = sprintf('|<img src="%s" valign="middle" width="22px"></img> %s | %s%s |'."\n",
                         $user_avatar,
                         $user,
                         "[$created](".$issue->{html_url}.")",
                         $labels ? " | $labels " : "");
    $header .= '|-|-|' . ($labels ? "-|" : "") . "\n\n";
    return $header . $body;
}

sub map_labels {
    my $config = shift;
    my $repo = shift;
    my $labels = shift;
    my $lmap = $config->{repos}->{$repo}->{label_mapping} || {};
    my @ret = ("module/$repo");
    
    for my $label (@$labels) {
        my $l = $label->{name};
        if ($lmap->{$l}) {
            push @ret, $lmap->{$l};
        } else {
            print "($l)";
        }
    }
    return \@ret;
}

sub map_milestone {
    my $milestone = shift;
    my $map = shift;
    if ($milestone) {
        my $id = $map->{$milestone->{title}};
        print "{",$milestone->{title},"}" unless $id;
        return $id;
    }
    return undef;
}

sub map_comment {
    my $comment = shift;
    
    my $body = $comment->{body};
    my $html_url = $comment->{html_url};
    my $user = "@" . $comment->{user}->{login};
    my $user_avatar = $comment->{user}->{avatar_url};
    my $created = $comment->{created_at};
    $created =~ s/.*(\d{4}-\d{2}-\d{2}).*/$1/;

    my $header = <<EOT;
| <img src="$user_avatar" height="22px"  valign="middle"></img> $user |  [$created]($html_url) |
|-|-|

EOT
    return $header . $body;
}

sub create_label_html {
    my $labels = shift || [];
    return join ", ", map { $_->{name} } @{$labels};
}


sub get_random_color {
    my $val = join "", map { sprintf "%02x", rand(255) } (0..2);
    return $val;
}

sub load_state {
    my $opts = shift;
    my $config = shift;
    my $file = $opts->{'state'} || $config->{'state'} || "issues_state.bin";
    if (-f $file) {
        return retrieve($file);
    } else {
        return {};
    }
}

sub save_state {
    my $opts = shift;
    my $config = shift;
    my $hash = shift;
    my $file = $opts->{'state'} || $config->{'state'} || "issues_state.bin";
    store $hash, $file unless $opts->{"dry-run"};
}

sub extract_milestones {
    my $opts = shift;
    my $config = shift;
    my $milestones = Pithub::Issues::Milestones->new(&parse_auth($opts, $config));
    my $ret = {};
    my $milestones_result = $milestones->list(&get_target_repo($opts, $config), auto_pagination => 1);
    while (my $milestone = $milestones_result->next) {
        $ret->{$milestone->{title}} = $milestone->{number};
    }
    return $ret;
}

sub get_target_repo {
    my $opts = shift;
    my $config = shift;
    return &parse_repo($opts->{target} || $config->{target});
}

sub parse_repo {
    my $name = shift;
    my @parts = split /\//,$name;
    die "Invalid repo name $name" if @parts != 2;
    return (
            user => $parts[0],
            repo => $parts[1]
           );
}

sub parse_auth {
    my $opts = shift;
    my $config = shift;
    my $user = $opts->{user} || $config->{auth}->{user};
    my $token = $opts->{token} || $config->{auth}->{token};
    die "No GitHub user provided" unless $user;
    die "No GitHub token provided" unless $token;
    return (
            user => $user,
            token => $token
           );    
}



