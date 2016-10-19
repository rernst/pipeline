package illumina_poststats;

use FindBin;
use lib "$FindBin::Bin";
use discipline;

use File::Basename;
use File::Spec::Functions;

use illumina_sge qw(qsubTemplate);
use illumina_jobs qw(getJobId);
use illumina_template qw(from_template);


sub runPostStats {
    my ($opt) = @_;

    my $done_file = catfile($opt->{OUTPUT_DIR}, "logs", "PostStats.done");

    if (-f $done_file) {
        say "WARNING: $done_file exists, skipping";
        return;
    }

    my @bam_files;
    my @running_jobs;
    foreach my $sample (keys %{$opt->{SAMPLES}}) {
        push @bam_files, catfile($opt->{OUTPUT_DIR}, $sample, "mapping", $opt->{BAM_FILES}->{$sample});
        if (@{$opt->{RUNNING_JOBS}->{$sample}}) {
            push(@running_jobs, join(",", @{$opt->{RUNNING_JOBS}->{$sample}}));
        }
    }

    my $job_id = "PostStats_" . getJobId();
    my $job_id_check = "PostStatsCheck_" . getJobId();
    my $bash_file = catfile($opt->{OUTPUT_DIR}, "jobs", "${job_id}.sh");
    my $log_dir = catfile($opt->{OUTPUT_DIR}, "logs");
    my $stdout = catfile($log_dir, "PostStats_$opt->{RUN_NAME}.out");
    my $stderr = catfile($log_dir, "PostStats_$opt->{RUN_NAME}.err");

    from_template("PostStats.sh.tt", $bash_file,
                  bam_files => \@bam_files,
                  job_id => $job_id,
                  job_id_check => $job_id_check,
                  opt => $opt);

    my $qsub = qsubTemplate($opt, "POSTSTATS");
    if (@running_jobs) {
        system "$qsub -o $stdout -e $stderr -N $job_id -hold_jid " . join(",", @running_jobs) . " $bash_file";
    } else {
        system "$qsub -o $stdout -e $stderr -N $job_id $bash_file";
    }

    $bash_file = catfile($opt->{OUTPUT_DIR}, "jobs", "${job_id_check}.sh");
    from_template("PostStatsCheck.sh.tt", $bash_file, opt => $opt);
    system "$qsub -o $stdout -e $stderr -N $job_id_check -hold_jid $job_id $bash_file";

    $opt->{RUNNING_JOBS}->{poststats} = [$job_id_check];
    return;
}

1;
