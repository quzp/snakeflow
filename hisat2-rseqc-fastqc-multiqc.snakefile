from os.path import join, isfile

############# Globals ######################################

configfile: 'config.yml'
#Workding directory
workdir: config['workdir']

# utils function
def unique(seq):
    """Remove duplicates from a list in Python while preserving order.
    :param seq: a python list object.
    :return: a list without duplicates while preserving order.
    """    
    seen = set()
    seen_add = seen.add

    return [x for x in seq if x not in seen and not seen_add(x)]

def parse_samples(tab=config['samples']['coldata']):
    """parse samples """
    SAMPLES=[]
    SAMPLES_ALIAS=[]
    GROUP=[]
    TIME=[]
    with open(tab, 'rU') as f:
        lines = f.readlines()
    for line in lines:
        line = line.strip()
        if not len(line) or line.startswith('#'): continue #skip blank line or comment linne
        item = line.split(" ")
        SAMPLES.append(item[0])
        SAMPLES_ALIAS.append(item[1])
        GROUP.append(item[2])
        TIME.append(item[3])

    return SAMPLES, SAMPLES_ALIAS, GROUP, TIME
################### globals #############################################

# Full path to an uncompressed FASTA file with all chromosome sequences.
CDNA = config['cdna']

# Full path to a folder that holds all of your FASTQ files.
FASTQ_DIR = config['fastq_dir']
READ_LEN = config['read_length']
PAIRED = 'paired' if config['paired'] else 'single'
# Full path to a Genome.
GENOME = config['genome']
#CDNA =           join(GENOME,"gencode.v25.transcripts.fa")
# genome sequence
FASTA_REF =     config['fasta']
# index_dir
HISAT2_REFDIR= config['hisat_index']
# index basename
INDEX_PREFIX = config['index_prefix']
# gtf
GTF_FILE =       config['gtf']
GTF_Genes =      GTF_FILE.rstrip(".gtf")+".extracted.genes.annotation.txt"
GTF_Trans =      GTF_FILE.rstrip(".gtf")+".extracted.transx2gene.txt"

#rseqc_annotation
RSEQC_ANNO  = config['rseqc']
############ Samples ##################
# A Snakemake regular expression matching the forward mate FASTQ files.
# the part in curly brackets {} will be saved, so the variable SAMPLES
# is a list of strings #['Sample1','Sample2'].

#notice that SAMPLES, has a trailing comma.
#you must include this trailing comma, or else the code won’t work correctly.

#SAMPLES, = glob_wildcards(join(FASTQ_DIR, '{sample, SRR[^/]+}_R1.fastq.gz'))
if isfile(config['samples']['coldata']):
    SAMPLES,SAMPLES_ALIAS,GROUP,TIME = parse_samples(config['samples']['coldata'])
else:
    SAMPLES = config['samples']['name'].split()
    SAMPLES_ALIAS = config['samples']['alias'].split()
    GROUP=config['samples']['group'].split()
    TIME=config['samples']['time'].split()

# Patterns for the 1st mate and the 2nd mate using the 'sample' wildcard.
#PATTERN_R1 = '{sample}_R1.fastq.gz'
#PATTERN_R2 = '{sample}_R2.fastq.gz'
PATTERN_R1 = config['read_pattern']['r1']
PATTERN_R2 = config['read_pattern']['r2']

#read suffix
for suf in ['.fastq.gz','.fq.gz','.fastq','.fq']:
    if PATTERN_R1.endswith(suf):
        READ_SUFFIX = suf

#PERRETY_SAMPLE = expand("mapped/{sample}.{replicate}.bam", sample=SAMPLES, replicate=[0, 1])
#SAMPLES,GROUP,IDS,= glob_wildcards(join(FASTQ_DIR, '{sample}_{group}_{id}_R1.fastq.gz'))

####### Tools dir#################
SCRIPTS = config['scripts']

# dirs 
DIRS = ['qc','mapped','counts','alternative_splicing', 'gene_expression',
        'differential_expression','logs','temp']

########### Target output files #################
MULTIQC = 'qc/multiqc_report.html'

################## Rules #######################################

rule target:
    input: MULTIQC,

rule fastqc:
    input:
        join(FASTQ_DIR,"{prefix}%s"%READ_SUFFIX),
    output:
        "qc/fastqc/{prefix}_fastqc.html",
        "qc/fastqc/{prefix}_fastqc.zip",

    shell: "fastqc -o qc/fastqc {input}"

rule hisat2_index:
    input:
        fasta = FASTA_REF,
        gtf = GTF_FILE,
    output: expand(join(HISAT2_REFDIR,INDEX_PREFIX)+".{ids}.ht2",ids=range(1,9))
    params:
        basename=join(HISAT2_REFDIR, INDEX_PREFIX)
    log: "logs/hisat2/hisat2.index.build.log"
    threads: 12
    shell: "hisat2-build -f {input.fasta}  -p {threads}  {params.basename} &> {log}"


rule hisat2_extract_splicesites:
    input: GTF_FILE
    output:
        splice = join(HISAT2_REFDIR, 'splicesites.txt'),
        exon =   join(HISAT2_REFDIR, 'exon.txt')
    threads: 12
    shell:
        """
        hisat2_extract_splice_sites.py {input} > {output.splice}
        hisat2_extract_exons.py {input} > {output.exon}
        """

rule hisat2_align:
    input:
        index=expand(join(HISAT2_REFDIR,INDEX_PREFIX)+".{ids}.ht2", ids=range(1,9)),
        site = join(HISAT2_REFDIR, "splicesites.txt"),
        r1 = join(FASTQ_DIR, PATTERN_R1),
        r2 = join(FASTQ_DIR, PATTERN_R2)
    output:
        temp('mapped/{sample}.bam')
    log:
        "logs/hisat2/{sample}.align.log"
    threads: 12
    params:
        ref = join(HISAT2_REFDIR, INDEX_PREFIX),
        extra="--min-intronlen 1000 --dta -t --new-summary"
    shell:
        "(hisat2 {params.extra} --threads {threads} -x {params.ref}"
        " -1 {input.r1} -2 {input.r2}  --known-splicesite-infile {input.site}"
        " | samtools view -Sbh -@ {threads}  -o {output} - ) 2> {log}"

rule bam_sort:
    input: "mapped/{sample}.bam"
    output: protected("mapped/{sample}.sorted.bam")
    threads: 12
    shell: "samtools sort -@ {threads} {input} > {output}"

rule bam_index:
    input: "mapped/{sample}.sorted.bam"
    output: "mapped/{sample}.sorted.bam.bai"
    shell: "samtools index {input}"

rule bam_stats:
    input:
        bam="mapped/{sample}.sorted.bam",
        bai="mapped/{sample}.sorted.bam.bai"
    output: "logs/rseqc/{sample}.bamstats.txt"
    shell: "bam_stat.py -i {input.bam} > {output}"

rule geneBody_coverage:
    input:
        bam="mapped/{sample}.sorted.bam",
        bai="mapped/{sample}.sorted.bam.bai",
        anno=RSEQC_ANNO['housekeep']
    output:
        "qc/rseqc/{sample}.geneBodyCoverage.r",
        "qc/rseqc/{sample}.geneBodyCoverage.txt"
    log:"logs/rseqc/{sample}.geneBodyCoverage.log"
    shell:
        "geneBody_coverage.py -r {input.anno} -i {input.bam}  -o qc/rseqc/{wildcards.sample} &> {log}"

rule read_distribution:
    input:
        bam="mapped/{sample}.sorted.bam",
        bai="mapped/{sample}.sorted.bam.bai",
        bed=RSEQC_ANNO['refseq']  
    output:
        "qc/rseqc/{sample}.readDistribution.txt"
    shell:
        "read_distribution.py -i {input.bam} -r {input.bed} > {output}"

rule htseq:
    input: 
        bam="mapped/{sample}.sorted.bam", 
        bai="mapped/{sample}.sorted.bam.bai",
        gtf=GTF_FILE,
    output: "counts/{sample}.htseq.tsv"
    log: "logs/htseq/{sample}.htseq-count.log"
    threads: 1
    shell: "htseq-count -r pos -s no -f bam {input.bam} {input.gtf}  > {output} 2> {log}"

rule multiqc:
    """Aggreate QC """
    input:
        expand(config['read_pattern']['fastqc'], sample=SAMPLES, suf='html'),
        expand("qc/rseqc/{sample}.geneBodyCoverage.txt", sample=SAMPLES,),
        expand("qc/rseqc/{sample}.readDistribution.txt",sample=SAMPLES),
        #expand("counts/{sample}.htseq.tsv",sample=SAMPLES)
    output: html='qc/multiqc_report.html'
    params:
        analysis_dir=config['workdir'],
        outdir="qc",
        extra="--config multiqc_config.yaml"
    shell: "multiqc --quiet --force -p -o {params.outdir} {params.analysis_dir}"
