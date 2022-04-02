import os

def read_todo_list(todo_list):
    with open(todo_list) as fi:
        lines = fi.readlines()
        lines = [x.strip() for x in lines]
    return lines

todo_list = read_todo_list(config['todo_list'])
root_dir = config['root_dir']

kraken_threads = 8

assert os.path.exists(root_dir)
if not os.path.exists(qc_results_dir):  
    os.makedirs(qc_results_dir)

## expand statement goes at the end (bottom) of each path in the dag
rule all:
    input:
        expand('{root_dir}/{sample}/{sample}_reads.assembly_stats.tsv', sample = todo_list, root_dir = root_dir),
        expand('{root_dir}/{sample}/kraken2/{sample}.kraken_report.txt', sample = todo_list, root_dir = root_dir),
        expand('{root_dir}/{sample}/Refseeker/{sample}.Refseeker.txt', sample = todo_list, root_dir = root_dir),
        expand('{root_dir}/{sample}/read_depth/{sample}.read_depth.txt', sample = todo_list, root_dir = root_dir)

rule assembly_stats:
    input:
        read = '{root_dir}/samples/{sample}'
    output:
        stats = '{root_dir}/{sample}_reads.assembly_stats.tsv'
    conda:
        '../../envs/assembly_stats.yaml'
    shell:
        'assembly-stats <(gzip -cd {input.read}) | tee {output.stats}'

rule kraken2:
   input:
        read = rules.assembly_stats.input.read,
        db = '/home/ubuntu/data/belson/kraken/' #replace with from config
   output:
       '{root_dir}/{sample}/kraken2/{sample}.kraken_report.txt'
   threads: kraken_threads
   conda:
       '../../envs/kraken2.yaml'
   shell:
       'kraken2 --gzip-compressed --use-names --output {output}  --db {input.db} --report {output} --threads {threads} --confidence 0.9 --memory-mapping {input.read}'
 
rule ref_seeker:
    input:
        read = rules.assembly_stats.input.read,
        db = '/home/ubuntu/data/belson/bacteria-refseq/' # Replace with config
    output:
        '{root_dir}/{sample}/Refseeker/{sample}.Refseeker.txt'
    conda:
        '../../envs/refseeker.yaml'
    shell:
        'referenceseeker {input.db} {input.read} | tee {output}'


##Reference seeker? If no reference genome given.
##Conditional logic within snakemake
##Mapping against a reference and getting depth
rule minimap:
	input:
		read = rules.assembly_stats.input.read,
		ref = '/home/ubuntu/data/belson/reference/2021.04.01/17762-33892_1_71_contigs.fa' # Put in the config 
	output:
		temp('{root_dir}/{sample}/minimap/{sample}.sam')
	shell:
		'minimap2 -ax map-ont {input.ref} {input.read} > {output}'

rule sam2bam:
	input:
		rules.minimap.output
	output:
		temp('{root_dir}/{sample}/minimap/{sample}.bam')
	shell:
        'samtools sort -@ 8 -o {output} {input}'

rule depth_calc:
	input:
		rules.sort_bam.output
	output:
		'{root_dir}/{sample}/minimap/{sample}_coverage.txt'
	shell:
		"samtools depth -aa {input} | awk '{{sum+=$3}} END {{print \"Average = \",sum/NR}}' > {output}"

##Nanopore assembly, polishing and annotation
rule flye:
	input:
		rules.assembly_stats.input.read
	output:
		directory('{results}/{sample}/{sample}Flye')
	conda:
		'/home/ubuntu/data/belson/Guppy5_guppy3_comparison/napa/scripts/envs/flye.yml'
	shell:
		'bash flye.sh {output} {input.nano}'

rule racon:
	input:
		genome = rules.flye.output,
		nano = rules.assembly_stats.input.read
	output:
		racon = temp('{results}/{sample}/{sample}RaconX1.fasta'),
		paf = temp('{results}/{sample}/{sample}.racon.paf')
	shell:
		'minimap2 -x map-ont {input.gen}/assembly.fasta {input.nano} > {output.paf} && racon -t 4 {input.nano} {output.paf} {input.gen}/assembly.fasta > {output.racon}'

rule medaka:
	input:
		gen = rules.racon.output.racon,
		nano = rules.assembly_stats.input.read
	output:
		directory('{results}/{sample}/{sample}medaka')
	conda:
		'/home/ubuntu/data/belson/isangi_nanopore/scripts/envs/medaka.yml'
	shell:
		'medaka_consensus -i {input.nano} -d {input.genome} -t 8  -m {model} -o {output}'

# Polca if illumina available + polypolish?
rule polish_medaka:
    input:
        gen = rules.medaka.output,
		r1 = lambda wildcards : config[wildcards.sample]["R1"],
        r2 =  lambda wildcards : config[wildcards.sample]["R2"]
    output:
        directory('{results}/{sample}/{sample}polishMedaka')
    shell:
        "polca.sh -a {input.gen}/consensus.fasta -r '{input.r1} {input.r2}' && mkdir {output} && mv consensus.fasta* {output}"

# Polypolish section
rule indexing:
    input:
        rules.medaka.output
    output:
        '{results}/{sample}/{sample}medaka/consensus.fasta.fai'
    rule:
        'bwa index {input}'

rule bwa:
    input:
        r1 = '{root_dir}/{sample}/{sample}_1.fastq.gz',
        r2 = '{root_dir}/{sample}/{sample}_2.fastq.gz',
        genome = rules.medaka.output
    output:
        sam1 = temp('{root_dir}/{sample}/{sample}_1.sam'),
        sam2 = temp('{root_dir}/{sample}/{sample}_2.sam')
    shell:
        '''
            bwa mem -t 16 -a {input.genome}/consensus.fasta {input.r1} > {output.sam1}
            bwa mem -t 16 -a {input.genome}/consensus.fasta {input.r2} > {output.sam2}
        '''

rule filter_alignments:
    input:
        aln1 = rules.bwa.output1,
        aln2 = rules.bwa.output2
    output:
        aln1 = '{root_dir}/{sample}/{sample}_filtered_1.sam',
        aln2 = '{root_dir}/{sample}/{sample}_filtered_2.sam'
    shell:
        'polypolish_insert_filter.py --in1 {input.aln1} --in2 {input.aln2} --out1 {output.aln1} --out2 {output.aln2}'

rule polypolish:
    input:
        genome = rules.medaka.output,
        aln1 = rules.filter_alignments.aln1,
        aln2 = rules.filter_alignments.aln2
    output:
        '{root_dir}/{sample}/Polish/{sample}_polished.fasta'
    shell:
        'polypolish {input.genome} {input.aln1} {input.aln2} > {output}'
#From Medaka or polypolish??
rule bakta:
    input:
        rules.medaka.output
    output:
        directory('{results}/{sample}Bakta')
    shell:
        'bakta --db /home/ubuntu/data/belson/bakta/db/db {input}/consensus.fasta -o {output}'