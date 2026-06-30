// =============================================================================
// pl_control.sv
// Unidade de Controle Principal -- RV32I pipelined (P&H secao 4.4)
//
// Decodifica o opcode de 7 bits (estagio ID) e gera os sinais de controle
// que serao propagados pelos registradores de pipeline.
//
// Instrucoes suportadas:
//   R-type  (0110011): add, and
//   I-type  (0000011): lw
//   S-type  (0100011): sw
//   B-type  (1100011): beq
//
// Tabela de sinais de controle:
//   Sinal     | R-type | lw | sw | beq
//   ----------|--------|----|----|-----
//   ALUSrc    |   0    |  1 |  1 |  0    0=reg, 1=imm
//   MemtoReg  |   0    |  1 |  - |  -    0=ALU, 1=mem
//   RegWrite  |   1    |  1 |  0 |  0
//   MemRead   |   0    |  1 |  0 |  0
//   MemWrite  |   0    |  0 |  1 |  0
//   Branch    |   0    |  0 |  0 |  1
//   ALUOp[1]  |   1    |  0 |  0 |  0
//   ALUOp[0]  |   0    |  0 |  0 |  1
// =============================================================================

`timescale 1ns / 1ps

module pl_control (
    input  logic [6:0] Opcode,
    output logic [1:0] ALUSrcA, // NOVO SINAL para lui
    output logic       ALUSrc,
    output logic       MemtoReg,
    output logic       RegWrite,
    output logic       MemRead,
    output logic       MemWrite,
    output logic       Branch,
    output logic [1:0] ALUOp
);

    localparam R_TYPE = 7'b0110011;
    localparam LOAD   = 7'b0000011;
    localparam STORE  = 7'b0100011;
    localparam BRANCH = 7'b1100011;
    localparam I_TYPE = 7'b0010011;
    localparam LUI   = 7'b0110111;
    localparam AUIPC = 7'b0010111;
    localparam JAL  = 7'b1101111;
    localparam JALR = 7'b1100111;

    always_comb begin
        ALUSrcA  = 2'b00; // Valor por defeito (usa rs1)
        ALUSrc   = 1'b0;
        MemtoReg = 1'b0;
        RegWrite = 1'b0;
        MemRead  = 1'b0;
        MemWrite = 1'b0;
        Branch   = 1'b0;
        ALUOp    = 2'b00;

        case (Opcode)
            R_TYPE: begin
                ALUSrc   = 1'b0;
                MemtoReg = 1'b0;
                RegWrite = 1'b1;
                ALUOp    = 2'b10;
            end
            I_TYPE: begin
                ALUSrc   = 1'b1;
                MemtoReg = 1'b0; // CORRIGIDO: 0 = Resultado vem da ALU
                RegWrite = 1'b1;
                MemRead  = 1'b0;
                ALUOp    = 2'b11;                
            end
            LOAD: begin
                ALUSrc   = 1'b1;
                MemtoReg = 1'b1; // CORRIGIDO: 1 = Resultado vem da Memória de Dados
                RegWrite = 1'b1;
                MemRead  = 1'b1;
                ALUOp    = 2'b00;
            end
            STORE: begin
                ALUSrc   = 1'b1;
                MemWrite = 1'b1;
                ALUOp    = 2'b00;
            end
            BRANCH: begin
                Branch   = 1'b1;
                ALUOp    = 2'b01;
            end
            LUI: begin
                ALUSrcA  = 2'b10; // SrcA = 0
                ALUSrc   = 1'b1;  // SrcB = Imediato
                RegWrite = 1'b1;
                ALUOp    = 2'b00; // Força a ALU a somar (0 + Imediato)
            end
            AUIPC: begin
                ALUSrcA  = 2'b01; // SrcA = PC
                ALUSrc   = 1'b1;  // SrcB = Imediato
                RegWrite = 1'b1;
                ALUOp    = 2'b00; // Força a ALU a somar (PC + Imediato)
            end

            JAL: begin
                ALUSrc   = 1'b1;
                MemtoReg = 1'b0; // O dado virá do "resultado da ALU" desviado
                RegWrite = 1'b1;
                MemRead  = 1'b0;
                MemWrite = 1'b0;
                Branch   = 1'b1; // Ativa a infraestrutura de branch
                ALUOp    = 2'b00; // Código JAL
            end
           
            JALR: begin
                ALUSrc   = 1'b1;
                MemtoReg = 1'b0;
                RegWrite = 1'b1;
                MemRead  = 1'b0;
                MemWrite = 1'b0;
                Branch   = 1'b1; // Ativa a infraestrutura de branch
                ALUOp    = 2'b11; // Código JALR
            end

            default: ; // sinais permanecem em zero (seguro)
        endcase
    end

endmodule
