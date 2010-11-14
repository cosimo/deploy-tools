package Bot::BasicBot::Pluggable::Module::Deployer;

use strict;
use warnings;

use base qw(Bot::BasicBot::Pluggable::Module);

use CGI ();
use HTML::Entities ();
use LWP::Simple ();
use LWP::UserAgent ();
use Term::ANSIColor qw(:constants);
use YAML ();

our $VERSION = '0.04';
our $BUILD_UPDATES_CHANNEL = '#build-updates';
our $HELPER_TOOLS_PATH = '.';

sub help {
    return "I keep track of deployments. Commands: projects-list, build-status <project>, latest-revision <project>";
}

sub said {
    my ($self, $mess, $pri) = @_;

    # Changed to pri 2 to allow other modules to be called
    return unless ($pri == 2);

    my $body = $mess->{body};
    my $chan = $mess->{channel};
    my $user = $mess->{who};

    if ($body =~ m{latest\-rev(?:ision)? \s* (\S*)}ix ) {
        my $project = $1;
        my ($rev, $text) = $self->latest_revision($project);
        if (! $rev) {
            return;
        }
        return $self->tell($chan, "$rev, $text");
    }

    elsif ($body =~ m{build\-status \s* (\S*)}ix) {
        my $project = $1;
        my $build_status = $self->build_status($project);

        if (! $build_status) {
            return;
        }

        return $self->tell($chan, $build_status);
    }

    elsif ($body =~ m{projects?\-list}) {
        my @projects = $self->projects_list();
        return $self->tell($chan, join(', ', @projects));
    }

    return;
}

sub project_repository_url {
    my ($self, $project) = @_;

    if (! defined $project || $project eq "") {
        return;
    }

    my $settings = $self->project_settings($project);
    my $repo_url = $settings->{repository}->{url};

    return $repo_url;
}

sub project_build_names {
    my ($self, $project) = @_;

    if (! defined $project || $project eq "") {
        return;
    }

    my $settings = $self->project_settings($project);
    my $builds = $settings->{'continuous-integration'}->{builds};

    if (! $builds || ref $builds ne 'ARRAY') {
        return;
    }

    if (@{ $builds } > 0 ) {
        return @{ $builds };
    }

    return;
}

sub build_status {
    my ($self, $project) = @_;

    if (! defined $project || $project eq "") {
        return 'build-status wants a project name...';
    }

    my $latest_revision = $self->latest_revision($project);
    my @build_names = $self->project_build_names($project);

    my $settings = $self->project_settings($project);

    my $text = "";
    my $ci_type = $settings->{'continuous-integration'}->{type};
    my $ci_server = $settings->{'continuous-integration'}->{server};

    for my $bname (@build_names) {
        my $build_status = `$HELPER_TOOLS_PATH/$ci_type-build-status --server $ci_server --project $bname | head -1`;
        chomp $build_status;
        $text .= $build_status . "\n";
    }

    if ($text =~ m{success}) {
        $text =~ s{success}{GREEN . 'success' . RESET}eg;
    }

    if ($text =~ m{failed}) {
        $text =~ s{failed}{RED . 'failed' . RESET}eg;
    }

    $text =~ s{\t+}{ }g;

    return $text;
}

sub latest_revision {
    my ($self, $project) = @_;

    if (! defined $project || $project eq "") {
        return;
    }

    my $repo = $self->project_repository_url($project);
    my $settings = $self->project_settings($project);
    my $changeset_url = $settings->{repository}->{changeset_url};

    my $latest_revision = `$HELPER_TOOLS_PATH/vcs-latest-revision '$repo'`;
    chomp $latest_revision;

    if ($changeset_url) {
        $changeset_url = sprintf($changeset_url, $latest_revision);
        return wantarray
            ? ($latest_revision, $changeset_url)
            : $latest_revision;
    }

    return $latest_revision;
}

sub load_build_status {
    my ($self) = @_;
    my $file = "./.build-status.conf";
    return {} unless -s $file;
    my $build_status = YAML::LoadFile($file);
    return $build_status;
}

sub save_build_status {
    my ($self, $new_build_status) = @_;
    my $file = "./.build-status.conf";
    return YAML::DumpFile($file, $new_build_status);
}

sub build_updates {
    my ($self) = @_;

    my @projects = $self->projects_list();
    my $store = $self->load_build_status();
    my @updates;

    for my $prj (@projects) {
        my $build_status = $self->build_status($prj);
        my $prev_status = $store->{$prj};
        if (defined $prev_status && $build_status ne $prev_status) {
            if ($build_status =~ m{incomplete}i) {
                push @updates, [ $prj => "$prj now building..." ];
            }
            else {
                push @updates, [ $prj => "$prj, $build_status" ];
            }
        }
        $store->{$prj} = $build_status;
    }

    $self->save_build_status($store);

    return \@updates;
}

sub tick {
    my ($self) = @_;

    my $updates = $self->build_updates();

    # No updates, see you in 1'
    return 10 unless $updates;

    for (@{ $updates }) {
        my ($prj, $build_status) = @{ $_ };
        $self->say(
            channel => $BUILD_UPDATES_CHANNEL,
            body => $build_status,
        );
    }

    return 10;
}

sub config_file_names {
    return qw(./deployer.conf ./deployer.yaml ~/.deployerrc /etc/deployer.conf /etc/deployer.yaml)
}

sub read_config {
    my ($self, $file) = @_;

    if (! $file) {
        my @candidates = config_file_names();
        for (@candidates) {
            ($file = $_, last) if -s $_ ;
        }
    }

    return unless $file;

    my $conf = YAML::LoadFile($file);

    return $conf;    
}

sub projects_list {
    my ($self) = @_;
    my $conf = $self->read_config();
    my $prj = $conf->{projects};
    my @prj = keys %{ $prj };
    return sort @prj;
}

sub project_settings {
    my ($self, $prj) = @_;
    my $conf = $self->read_config();
    if (! $conf || ! exists $conf->{projects}->{$prj}) {
        return;
    }
    return $conf->{projects}->{$prj};
}

1;

