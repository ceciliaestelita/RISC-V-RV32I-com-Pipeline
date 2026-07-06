// =============================================================================
// pl_datapath.sv
// Datapath pipeline de 5 estagios -- RV32I (P&H secoes 4.6-4.10)
//
// Estagios:
//   IF  -- busca instrucao (pl_imem, PC)
//   ID  -- decodificacao, leitura de registradores, deteccao de hazard
//   EX  -- execucao (ALU), resolucao de branch, forwarding
//   MEM -- acesso a memoria de dados / MMIO
//   WB  -- escrita no banco de registradores
//
// Tratamento de hazards:
//   Load-use stall : 1 ciclo de bolha (pl_hazard)
//   RAW data       : forwarding EX/MEM -> EX e MEM/WB -> EX (pl_forward)
//   Branch taken   : flush de IF e ID (2 NOPs) na resolucao in EX
//
// Decodificacao de endereco (estagio MEM):
//   alu_result[10] = 0 -> memoria de dados  (0x000-0x3FF)
//   alu_result[10] = 1 -> MMIO              (0x400-0x7FF)
//     alu_result[4:2] seleciona periferico dentro da janela MMIO
// =============================================================================

`timescale 1ns / 1ps

import pl_pipe_pkg::*;

module pl_datapath (
    input  logic        clk,
    input  logic        rst_n,

    // Sinais de controle vindos do estagio ID (pl_control)
    input  logic [1:0]  ALUSrcA,
    input  logic        ALUSrc,
    input  logic        MemtoReg,
    input  logic        RegWrite,
    input  logic        MemRead,
    input  logic        MemWrite,
    input  logic        Branch,
    input  logic [1:0]  ALUOp,

    // Codigo de operacao da ALU (pl_alu_ctrl, usa campos do estagio EX)
    input  logic [3:0]  ALU_CC,

    // Campos realimentados ao pl_cpu para controle e ALU ctrl
    output logic [6:0]  Opcode,       // opcode do estagio ID (para pl_control)
    output logic [2:0]  Funct3_EX,    // funct3 do estagio EX (para pl_alu_ctrl)
    output logic [6:0]  Funct7_EX,    // funct7 do estagio EX (para pl_alu_ctrl)
    output logic [1:0]  ALUOp_EX,     // ALUOp do estagio EX  (para pl_alu_ctrl)

    output logic [31:0] PC,           // PC atual (testbench / debug)

    // E/S Mapeada em Memoria -- DE2-115
    input  logic [17:0] SW,
    input  logic [3:0]  KEY,
    output logic [17:0] LEDR,
    output logic [8:0]  LEDG,
    output logic        UART_TXD,
    input  logic        UART_RXD,

    // Observabilidade para o testbench
    output logic        wb_reg_write,   // pulso quando WB escreve registrador
    output logic [4:0]  wb_reg_dst,     // registrador destino (WB)
    output logic [31:0] wb_reg_data,    // dado escrito (WB)
    output logic        mem_wr_en,      // escrita na dmem (nao MMIO)
    output logic [7:0]  mem_wr_addr,    // endereco de palavra da dmem (MEM)
    output logic [31:0] mem_wr_data     // dado escrito na dmem (MEM)
);

    // =========================================================================
    // Sinais internos
    // =========================================================================

    // PC
    logic [31:0] pc_reg, pc_plus4;

    // Registradores de pipeline
    if_id_t  if_id;
    id_ex_t  id_ex;
    ex_mem_t ex_mem;
    mem_wb_t mem_wb;

    // Hazard / branch
    logic        stall;
    logic        pc_src;
    logic [31:0] branch_target;

    // ID
    logic [31:0] rd1, rd2, imm_ext;

    // EX -- forwarding
    logic [1:0]  fwd_a, fwd_b;
    logic [31:0] fwd_srca, fwd_srcb, alu_srcb;
    logic [31:0] alu_result;
    logic        zero;

    // WB
    logic [31:0] wb_data;

    // MEM
    logic        mmio_sel;
    logic [31:0] dmem_rd, mmio_rd, mem_read_data;

    // =========================================================================
    // IF -- Busca de instrucao
    // =========================================================================
    logic [31:0] instr_if;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)      pc_reg <= 32'b0;
        else if (pc_src) pc_reg <= branch_target;   // branch tem prioridade
        else if (!stall) pc_reg <= pc_plus4;
        // else stall: PC mantido
    end

    assign PC       = pc_reg;
    assign pc_plus4 = pc_reg + 32'd4;

    pl_imem imem (
        .addr  (pc_reg[9:2]),
        .instr (instr_if)
    );

    // =========================================================================
    // Registrador IF/ID
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin                    // reset assicrono (unico sinal na lista)
            if_id.pc    <= 32'b0;
            if_id.instr <= 32'b0;
        end else if (pc_src) begin           // flush sincrono: branch taken
            if_id.pc    <= 32'b0;
            if_id.instr <= 32'b0;
        end else if (!stall) begin           // avanco normal
            if_id.pc    <= pc_reg;
            if_id.instr <= instr_if;
        end
        // else stall: mantido
    end

    // =========================================================================
    // ID -- Decodificacao, banco de registradores, imediato, hazard
    // =========================================================================
    assign Opcode = if_id.instr[6:0];

    // Deteccao de hazard load-use
    pl_hazard hazard (
        .if_id_rs1      (if_id.instr[19:15]),
        .if_id_rs2      (if_id.instr[24:20]),
        .id_ex_rd       (id_ex.rd),
        .id_ex_mem_read (id_ex.mem_read),
        .stall          (stall)
    );

    // Dado de write-back (mux WB): usado tambem pelo forwarding MEM/WB->EX
    assign wb_data = mem_wb.mem_to_reg ? mem_wb.read_data : mem_wb.alu_result;

    pl_regfile regfile (
        .clk       (clk),
        .RegWrite  (mem_wb.reg_write),
        .rs1       (if_id.instr[19:15]),
        .rs2       (if_id.instr[24:20]),
        .rd        (mem_wb.rd),
        .WriteData (wb_data),
        .ReadData1 (rd1),
        .ReadData2 (rd2)
    );

    pl_sign_ext sign_ext (
        .Instr  (if_id.instr),
        .ImmExt (imm_ext)
    );

    // Saidas para o testbench (estagio WB)
    assign wb_reg_write = mem_wb.reg_write;
    assign wb_reg_dst   = mem_wb.rd;
    assign wb_reg_data  = wb_data;

    // =========================================================================
    // Registrador ID/EX
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin      
            id_ex.alu_src_a  <= 2'b00;                // reset assicrono (unico sinal na lista)
            id_ex.alu_src    <= 1'b0;
            id_ex.mem_to_reg <= 1'b0;
            id_ex.reg_write  <= 1'b0;
            id_ex.mem_read   <= 1'b0;
            id_ex.mem_write  <= 1'b0;
            id_ex.alu_op     <= 2'b00;
            id_ex.branch     <= 1'b0;
            id_ex.pc         <= 32'b0;
            id_ex.rd1        <= 32'b0;
            id_ex.rd2        <= 32'b0;
            id_ex.rs1        <= 5'b0;
            id_ex.rs2        <= 5'b0;
            id_ex.rd         <= 5'b0;
            id_ex.imm_ext    <= 32'b0;
            id_ex.funct3     <= 3'b0;
            id_ex.funct7     <= 7'b0;
        end else if (stall || pc_src) begin
            id_ex.alu_src_a  <= 2'b00;    // NOP sincrono: load-use ou branch
            id_ex.alu_src    <= 1'b0;
            id_ex.mem_to_reg <= 1'b0;
            id_ex.reg_write  <= 1'b0;
            id_ex.mem_read   <= 1'b0;
            id_ex.mem_write  <= 1'b0;
            id_ex.alu_op     <= 2'b00;
            id_ex.branch     <= 1'b0;
            id_ex.pc         <= 32'b0;
            id_ex.rd1        <= 32'b0;
            id_ex.rd2        <= 32'b0;
            id_ex.rs1        <= 5'b0;
            id_ex.rs2        <= 5'b0;
            id_ex.rd         <= 5'b0;
            id_ex.imm_ext    <= 32'b0;
            id_ex.funct3     <= 3'b0;
            id_ex.funct7     <= 7'b0;
        end else begin
            id_ex.alu_src_a  <= ALUSrcA;
            id_ex.alu_src    <= ALUSrc;
            id_ex.mem_to_reg <= MemtoReg;
            id_ex.reg_write  <= RegWrite;
            id_ex.mem_read   <= MemRead;
            id_ex.mem_write  <= MemWrite;
            id_ex.alu_op     <= ALUOp;
            id_ex.branch     <= Branch;
            id_ex.pc         <= if_id.pc;
            id_ex.rd1        <= rd1;
            id_ex.rd2        <= rd2;
            id_ex.rs1        <= if_id.instr[19:15];
            id_ex.rs2        <= if_id.instr[24:20];
            id_ex.rd         <= if_id.instr[11:7];
            id_ex.imm_ext    <= imm_ext;
            id_ex.funct3     <= if_id.instr[14:12];
            id_ex.funct7     <= if_id.instr[31:25];
        end
    end

    // Realimentacao para pl_alu_ctrl (usa campos do estagio EX)
    assign Funct3_EX = id_ex.funct3;
    assign Funct7_EX = id_ex.funct7;
    assign ALUOp_EX  = id_ex.alu_op;

    // =========================================================================
    // EX -- Forwarding, ALU, resolucao de branch
    // =========================================================================
    pl_forward forward (
        .id_ex_rs1        (id_ex.rs1),
        .id_ex_rs2        (id_ex.rs2),
        .ex_mem_rd        (ex_mem.rd),
        .mem_wb_rd        (mem_wb.rd),
        .ex_mem_reg_write (ex_mem.reg_write),
        .mem_wb_reg_write (mem_wb.reg_write),
        .forward_a        (fwd_a),
        .forward_b        (fwd_b)
    );

    // Mux de forwarding para SrcA
    always_comb begin
        case (fwd_a)
            2'b10:   fwd_srca = ex_mem.alu_result;
            2'b01:   fwd_srca = wb_data;
            default: fwd_srca = id_ex.rd1;
        endcase
    end

    // Mux de forwarding para SrcB (antes do mux ALUSrc)
    always_comb begin
        case (fwd_b)
            2'b10:   fwd_srcb = ex_mem.alu_result;
            2'b01:   fwd_srcb = wb_data;
            default: fwd_srcb = id_ex.rd2;
        endcase
    end

    // Mux ALUSrcA para decidir a entrada A da ALU (U-type suporte)
    logic [31:0] alu_srca_final;
    always_comb begin
        case (id_ex.alu_src_a)
            2'b01:   alu_srca_final = id_ex.pc;            // AUIPC usa o PC
            2'b10:   alu_srca_final = 32'b0;               // LUI usa Zero
            default: alu_srca_final = fwd_srca;            // Normal (rs1 via forwarding)
        endcase
    end

    // Mux ALUSrc: imediato ou registrador
    assign alu_srcb = id_ex.alu_src ? id_ex.imm_ext : fwd_srcb;

    // Fio para capturar a saída bruta da ALU
    logic [31:0] alu_result_raw;

    pl_alu alu (
        .SrcA      (alu_srca_final),
        .SrcB      (alu_srcb),
        .Operation (ALU_CC),
        .ALUResult (alu_result_raw), 
        .Zero      (zero)
    );

    // =========================================================================
    // Lógica de JAL e JALR (Saltos incondicionais e salvamento do retorno)
    // =========================================================================
    logic is_jal, is_jalr;

    // Identificamos os jumps pelo ALUOp combinado com o Branch=1
    assign is_jal  = id_ex.branch && (id_ex.alu_op == 2'b00);
    assign is_jalr = id_ex.branch && (id_ex.alu_op == 2'b11);

    // Mux que salva PC+4 no registrador de destino se for Jump.
    // Caso contrário, salva o resultado normal da ALU.
    assign alu_result = (is_jal || is_jalr) ? (id_ex.pc + 4) : alu_result_raw;

    // =========================================================================
    // Comparador de Branch Dedicado e Cálculo de Alvo
    // =========================================================================
    logic branch_condition_met;
   
    always_comb begin
        branch_condition_met = 1'b0; // Valor por defeito
       
        if (id_ex.branch) begin
            case (id_ex.funct3)
                3'b000: branch_condition_met = (fwd_srca == fwd_srcb);                   // BEQ
                3'b001: branch_condition_met = (fwd_srca != fwd_srcb);                   // BNE
                3'b100: branch_condition_met = ($signed(fwd_srca) < $signed(fwd_srcb));  // BLT
                3'b101: branch_condition_met = ($signed(fwd_srca) >= $signed(fwd_srcb)); // BGE
                3'b110: branch_condition_met = (fwd_srca < fwd_srcb);                    // BLTU
                3'b111: branch_condition_met = (fwd_srca >= fwd_srcb);                   // BGEU
                default: branch_condition_met = 1'b0;
            endcase
        end
    end

    // O alvo do JALR é (rs1 + imediato) com o bit 0 limpo.
    // Para JAL e Branches normais, o alvo é (PC + imediato).
    assign branch_target = is_jalr ? ((fwd_srca + id_ex.imm_ext) & 32'hFFFFFFFE) : (id_ex.pc + id_ex.imm_ext);
   
    // O PC deve desviar se a condição do branch for verdadeira OU se for JAL/JALR
    assign pc_src = branch_condition_met || is_jal || is_jalr;

    // =========================================================================
    // Registrador EX/MEM
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex_mem.mem_to_reg  <= 1'b0;
            ex_mem.reg_write   <= 1'b0;
            ex_mem.mem_read    <= 1'b0;
            ex_mem.mem_write   <= 1'b0;
            ex_mem.alu_result  <= 32'b0;
            ex_mem.write_data  <= 32'b0;
            ex_mem.rd          <= 5'b0;
            ex_mem.funct3      <= 3'b0;
        end else begin
            ex_mem.mem_to_reg  <= id_ex.mem_to_reg;
            ex_mem.reg_write   <= id_ex.reg_write;
            ex_mem.mem_read    <= id_ex.mem_read;
            ex_mem.mem_write   <= id_ex.mem_write;
            ex_mem.alu_result  <= alu_result;
            ex_mem.write_data  <= fwd_srcb;   // rs2 adiantado (para SW/MMIO/SB/SH)
            ex_mem.rd          <= id_ex.rd;
            ex_mem.funct3      <= id_ex.funct3;
        end
    end

    // =========================================================================
    // MEM -- Memoria de dados + MMIO
    // =========================================================================
    assign mmio_sel = ex_mem.alu_result[10];

    // O offset são os 2 bits menos significativos do endereço calculado
    logic [1:0] offset;
    assign offset = ex_mem.alu_result[1:0];

    // === NOVO: ADICIONADO PARA STORES (SB, SH, SW) ===
    logic [31:0] mem_write_data_formatted;
    logic [3:0]  mem_write_mask;
    
    // 1. Alinhamento e Replicação de Dados de Escrita
    always_comb begin
        case (ex_mem.funct3)
            3'b000:  mem_write_data_formatted = {4{ex_mem.write_data[7:0]}};  // SB: replica o byte 4 vezes
            3'b001:  mem_write_data_formatted = {2{ex_mem.write_data[15:0]}}; // SH: replica a halfword 2 vezes
            default: mem_write_data_formatted = ex_mem.write_data;           // SW: palavra inteira
        endcase
    end

    // 2. Geração da Máscara de Escrita (Byte Enables) baseada no offset
    always_comb begin
        mem_write_mask = 4'b0000; // Por padrão, nenhuma escrita ocorre
        
        // Só gera a máscara se for uma operação de escrita de fato e NÃO for MMIO
        if (ex_mem.mem_write && !mmio_sel) begin
            case (ex_mem.funct3)
                3'b000: begin // SB (Store Byte)
                    case (offset)
                        2'b00: mem_write_mask = 4'b0001;
                        2'b01: mem_write_mask = 4'b0010;
                        2'b10: mem_write_mask = 4'b0100;
                        2'b11: mem_write_mask = 4'b1000;
                    endcase
                end
                3'b001: begin // SH (Store Halfword)
                    case (offset[1])
                        1'b0:    mem_write_mask = 4'b0011; // Metade inferior
                        1'b1:    mem_write_mask = 4'b1100; // Metade superior
                    endcase
                end
                3'b010:  mem_write_mask = 4'b1111; // SW (Store Word - escreve tudo)
                default: mem_write_mask = 4'b0000;
            endcase
        end
    end

    // Instanciação da dmem adaptada para receber a Máscara de 4 bits (no lugar do bit simples de MemWrite)
    pl_dmem dmem (
        .clk       (clk),
        .MemWrite  (mem_write_mask),               // MUDADO: agora passa a máscara de 4 bits
        .addr      (ex_mem.alu_result[9:2]),
        .WriteData (mem_write_data_formatted),      // MUDADO: passa o dado replicado/alinhado
        .ReadData  (dmem_rd)
    );

    // MMIO continua operando em 32-bits Word normal
    pl_mmio mmio (
        .clk       (clk),
        .rst_n     (rst_n),
        .MemWrite  (ex_mem.mem_write &  mmio_sel),
        .MemRead   (ex_mem.mem_read  &  mmio_sel),
        .addr      (ex_mem.alu_result[4:2]),
        .WriteData (ex_mem.write_data),
        .SW        (SW),
        .KEY       (KEY),
        .ReadData  (mmio_rd),
        .LEDR      (LEDR),
        .LEDG      (LEDG),
        .UART_TXD  (UART_TXD),
        .UART_RXD  (UART_RXD)
    );

    // --- LÓGICA DE LOADS (LB, LH, LW, LBU, LHU) ---
    logic [7:0]  byte_read;
    logic [15:0] hw_read;
    logic [31:0] dmem_read_data_formatted;

    always_comb begin
        // 1. Extrair o byte correto baseado no offset
        case (offset)
            2'b00: byte_read = dmem_rd[7:0];
            2'b01: byte_read = dmem_rd[15:8];
            2'b10: byte_read = dmem_rd[23:16];
            2'b11: byte_read = dmem_rd[31:24];
        endcase

        // 2. Extrair a halfword correta baseado no bit 1 do offset
        case (offset[1])
            1'b0: hw_read = dmem_rd[15:0];
            1'b1: hw_read = dmem_rd[31:16];
        endcase

        // 3. Formatar o dado final baseado na instrução (funct3)
        case (ex_mem.funct3)
            3'b000: dmem_read_data_formatted = {{24{byte_read[7]}}, byte_read}; // LB  (Extensão de Sinal)
            3'b001: dmem_read_data_formatted = {{16{hw_read[15]}}, hw_read};    // LH  (Extensão de Sinal)
            3'b010: dmem_read_data_formatted = dmem_rd;                         // LW  (Palavra Inteira)
            3'b100: dmem_read_data_formatted = {24'b0, byte_read};              // LBU (Extensão com Zeros)
            3'b101: dmem_read_data_formatted = {16'b0, hw_read};                // LHU (Extensão com Zeros)
            default: dmem_read_data_formatted = dmem_rd;
        endcase
    end

    // Seleciona o dado final formatado em vez do dado cru da memória
    assign mem_read_data = mmio_sel ? mmio_rd : dmem_read_data_formatted;

    // Saidas de observabilidade para o testbench
    assign mem_wr_en   = ex_mem.mem_write & ~mmio_sel;
    assign mem_wr_addr = ex_mem.alu_result[9:2];
    assign mem_wr_data = mem_write_data_formatted;     // Atualizado para o testbench ver o dado formatado

    // =========================================================================
    // Registrador MEM/WB
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_wb.mem_to_reg <= 1'b0;
            mem_wb.reg_write  <= 1'b0;
            mem_wb.alu_result <= 32'b0;
            mem_wb.read_data  <= 32'b0;
            mem_wb.rd         <= 5'b0;
        end else begin
            mem_wb.mem_to_reg <= ex_mem.mem_to_reg;
            mem_wb.reg_write  <= ex_mem.reg_write;
            mem_wb.alu_result <= ex_mem.alu_result;
            mem_wb.read_data  <= mem_read_data;
            mem_wb.rd         <= ex_mem.rd;
        end
    end

endmodule
