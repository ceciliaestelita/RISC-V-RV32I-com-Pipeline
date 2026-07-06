// =============================================================================
// pl_dmem.sv
// Memoria de dados -- RV32I pipelined
//
// Capacidade : 256 palavras x 32 bits = 1 KB
// Init file  : data.mif   (sintese Quartus)
//              data.hex   (simulacao ModelSim via $readmemh)
//
// Leitura  : assincrona (combinatorial) -- disponivel no estagio MEM
// Escrita  : sincrona (posedge clk, gated por MemWrite & ~mmio_sel)
// Endereco : alu_result[9:2]  (endereco de palavra de 8 bits)
// =============================================================================

`timescale 1ns / 1ps

module pl_dmem (
    input  logic        clk,
    input  logic        MemWrite,
    input  logic [3:0]  ByteEnable,
    input  logic [7:0]  addr,
    input  logic [31:0] WriteData,
    output logic [31:0] ReadData
);

    (* ram_init_file = "data.mif" *) logic [31:0] ram [0:255];

    // synthesis translate_off
    initial begin
        for (int i = 0; i < 256; i++) ram[i] = 32'h00000000;
        $readmemh("data.hex", ram);
    end
    // synthesis translate_on

    //Escrita sincrona com Byte Enable (para inferir RAM com byteena no Quartus)
    always@(posedge clk) begin
        if (MemWrite) begin
            if (ByteEnable[0]) ram[addr][7:0] <= WriteData[7:0];
            if (ByteEnable[1]) ram[addr][15:8] <= WriteData[15:8];
            if (ByteEnable[2]) ram[addr][23:16] <= WriteData[23:16]; 
            if (ByteEnable[3]) ram[addr][31:24] <= WriteData[31:24];
        end
    end

    assign ReadData = ram[addr];

endmodule
