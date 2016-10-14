package illumina_jobs;

use 5.16.0;
use strict;
use warnings;

use File::Basename;
use File::Spec::Functions;
use POSIX qw(tmpnam);

use FindBin;
use lib "$FindBin::Bin";

use parent qw(Exporter);
our @EXPORT_OK = qw(
                       getJobId
                       fromTemplate
                       sliceBam
                       flagstatBam
                       diffBams
                       prePostBamSliceAndDiff
               );

use illumina_sge qw(qsubTemplate);
use illumina_template qw(from_template);


sub getJobId {
    my $id = fileparse(tmpnam());
    $id =~ s#(file|tmp\.[0-9]+\.)##;
    return $id;
}

sub fromTemplate {
    my ($name, $sample, $qsub, $hold_jids, $dirs, $opt, %params) = @_;

    my $suffix;
    $suffix = "_${sample}" if $sample;

    my $done_file = catfile($dirs->{log}, "${name}${suffix}.done");
    if (-f $done_file) {
        say "WARNING: $done_file exists, skipping";
        return;
    }

    my $job_id = "${name}${suffix}_" . getJobId();
    my $bash_file = catfile($dirs->{job}, "${job_id}.sh");

    from_template("${name}.sh.tt", $bash_file,
                  dirs => $dirs,
                  opt => $opt,
                  %params);

    my $stdout = catfile($dirs->{log}, "${name}${suffix}.out");
    my $stderr = catfile($dirs->{log}, "${name}${suffix}.err");
    my $hold_jid;
    $hold_jid = "-hold_jid " . join ",", @{$hold_jids} if @{$hold_jids};
    system "$qsub -o $stdout -e $stderr -N $job_id $hold_jid $bash_file";
    return $job_id;
}

sub sliceBam {
    my ($sample, $sample_bam, $sliced_bam, $bed_name, $hold_jids, $dirs, $opt) = @_;

    return fromTemplate(
        "SliceBam",
        $sample,
        qsubTemplate($opt, "FLAGSTAT"),
        $hold_jids,
        $dirs,
        $opt,
        sample => $sample,
        sample_bam => $sample_bam,
        input_bam => catfile($dirs->{mapping}, $sample_bam),
        bed_file => catfile($opt->{OUTPUT_DIR}, "settings", "slicing", $bed_name),
        sliced_bam => catfile($dirs->{mapping}, $sliced_bam));
}

sub flagstatBam {
    my ($sample, $sample_bam_path, $sample_flagstat_path, $hold_jids, $dirs, $opt) = @_;

    return fromTemplate(
        "Flagstat",
        $sample,
        qsubTemplate($opt, "FLAGSTAT"),
        $hold_jids,
        $dirs,
        $opt,
        sample => $sample,
        sample_bam_path => $sample_bam_path,
        sample_flagstat_path => $sample_flagstat_path);
}

sub diffBams {
    my ($sample, $input_bam1, $input_bam2, $diff_name, $hold_jids, $dirs, $opt) = @_;

    return fromTemplate(
        "DiffBams",
        $sample,
        qsubTemplate($opt, "FLAGSTAT"),
        $hold_jids,
        $dirs,
        $opt,
        sample => $sample,
        diff_name => $diff_name,
        input_bam1 => catfile($dirs->{mapping}, $input_bam1),
        input_bam2 => catfile($dirs->{mapping}, $input_bam2),
        output_diff => catfile($dirs->{mapping}, $diff_name));
}

sub prePostSliceAndDiffBams {
    my ($sample, $operation, $pre_bam, $post_bam, $hold_jids, $dirs, $opt) = @_;

    (my $pre_sliced_bam = $pre_bam) =~ s/\.bam$/.qc.pre${operation}.sliced.bam/;
    (my $post_sliced_bam = $pre_bam) =~ s/\.bam$/.qc.post${operation}.sliced.bam/;
    (my $post_sliced_flagstat = $pre_bam) =~ s/\.bam$/.qc.post${operation}.sliced.flagstat/;
    (my $pre_post_diff = $pre_bam) =~ s/\.bam$/.qc.prepost${operation}.diff/;

    my $post_sliced_bam_path = catfile($dirs->{mapping}, $post_sliced_bam);
    my $post_sliced_flagstat_path = catfile($dirs->{mapping}, $post_sliced_flagstat);

    my $pre_job_id = sliceBam($sample, $pre_bam, $pre_sliced_bam, "HealthCheck_Slicing.bed", $hold_jids, $dirs, $opt);
    my $post_job_id = sliceBam($sample, $post_bam, $post_sliced_bam, "HealthCheck_Slicing.bed", $hold_jids, $dirs, $opt);
    my $diff_job_id = diffBams($sample, $pre_sliced_bam, $post_sliced_bam, $pre_post_diff, [$pre_job_id, $post_job_id], $dirs, $opt);
    my $flagstat_job_id = flagstatBam($sample, $post_sliced_bam_path, $post_sliced_flagstat_path, [$post_job_id], $dirs, $opt);

    return [$diff_job_id, $flagstat_job_id];
}

1;